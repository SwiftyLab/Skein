#include "TorrentBridge.hpp"

#include <atomic>
#include <cstdio>
#include <exception>
#include <memory>
#include <shared_mutex>
#include <unordered_map>

#include <libtorrent/alert_types.hpp>
#include <libtorrent/extensions/smart_ban.hpp>
#include <libtorrent/extensions/ut_metadata.hpp>
#include <libtorrent/extensions/ut_pex.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/posix_disk_io.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <openssl/crypto.h>
#include <openssl/opensslv.h>

namespace torrentbridge {
namespace {

/// Maps our settings onto libtorrent's settings_pack.
///
/// Split out so session creation and later updates cannot drift apart: both go
/// through here, and `includeStartupOnly` marks the few that only apply before
/// the session is running.
void applyConfig(lt::settings_pack &settings, const SessionConfig &config,
                 bool includeStartupOnly) {
    if (includeStartupOnly) {
        settings.set_str(lt::settings_pack::listen_interfaces, config.listenInterfaces);
    }
    settings.set_str(lt::settings_pack::user_agent, config.userAgent);
    settings.set_bool(lt::settings_pack::enable_dht, config.enableDHT);
    settings.set_bool(lt::settings_pack::enable_lsd, config.enableLSD);
    settings.set_bool(lt::settings_pack::enable_upnp, config.enableUPnP);
    settings.set_bool(lt::settings_pack::enable_natpmp, config.enableNATPMP);
    settings.set_int(lt::settings_pack::download_rate_limit, config.downloadRateLimit);
    settings.set_int(lt::settings_pack::upload_rate_limit, config.uploadRateLimit);

    if (config.maxActiveDownloads >= 0) {
        settings.set_int(lt::settings_pack::active_downloads, config.maxActiveDownloads);
    }
    if (config.maxActiveSeeds >= 0) {
        settings.set_int(lt::settings_pack::active_seeds, config.maxActiveSeeds);
    }
    if (config.maxConnections >= 0) {
        settings.set_int(lt::settings_pack::connections_limit, config.maxConnections);
    }

    // libtorrent splits encryption into incoming and outgoing policy plus a
    // preference for the RC4 level; keep the three consistent.
    int policy = lt::settings_pack::pe_enabled;
    switch (config.encryption) {
    case EncryptionPolicy::disabled: policy = lt::settings_pack::pe_disabled; break;
    case EncryptionPolicy::required: policy = lt::settings_pack::pe_forced; break;
    case EncryptionPolicy::enabled:  policy = lt::settings_pack::pe_enabled; break;
    }
    settings.set_int(lt::settings_pack::out_enc_policy, policy);
    settings.set_int(lt::settings_pack::in_enc_policy, policy);
    settings.set_int(lt::settings_pack::allowed_enc_level,
                     config.encryption == EncryptionPolicy::required
                         ? lt::settings_pack::pe_rc4
                         : lt::settings_pack::pe_both);

    int proxyType = lt::settings_pack::none;
    switch (config.proxy.kind) {
    case ProxyKind::none: proxyType = lt::settings_pack::none; break;
    case ProxyKind::socks4: proxyType = lt::settings_pack::socks4; break;
    case ProxyKind::socks5:
        proxyType = config.proxy.username.empty() ? lt::settings_pack::socks5
                                                  : lt::settings_pack::socks5_pw;
        break;
    case ProxyKind::http:
        proxyType = config.proxy.username.empty() ? lt::settings_pack::http
                                                  : lt::settings_pack::http_pw;
        break;
    }
    settings.set_int(lt::settings_pack::proxy_type, proxyType);
    settings.set_str(lt::settings_pack::proxy_hostname, config.proxy.host);
    settings.set_int(lt::settings_pack::proxy_port, config.proxy.port);
    settings.set_str(lt::settings_pack::proxy_username, config.proxy.username);
    settings.set_str(lt::settings_pack::proxy_password, config.proxy.password);
    settings.set_bool(lt::settings_pack::proxy_peer_connections,
                      config.proxy.proxyPeerConnections);
    settings.set_bool(lt::settings_pack::proxy_hostnames, config.proxy.proxyHostnames);
}

std::string hexInfoHash(const lt::info_hash_t &hashes) {
    // to_string() yields the raw 20 bytes; to_hex renders them as 40 hex chars.
    return lt::to_hex(hashes.get_best().to_string());
}

TorrentState mapState(lt::torrent_status::state_t state) {
    switch (state) {
    case lt::torrent_status::checking_files:        return TorrentState::checkingFiles;
    case lt::torrent_status::downloading_metadata:  return TorrentState::downloadingMetadata;
    case lt::torrent_status::downloading:           return TorrentState::downloading;
    case lt::torrent_status::finished:              return TorrentState::finished;
    case lt::torrent_status::seeding:               return TorrentState::seeding;
    case lt::torrent_status::checking_resume_data:  return TorrentState::checkingResumeData;
    default:                                        return TorrentState::unknown;
    }
}

TorrentSnapshot makeSnapshot(const lt::torrent_status &status) {
    TorrentSnapshot snapshot;
    snapshot.infoHash = hexInfoHash(status.info_hashes);
    snapshot.name = status.name;
    snapshot.savePath = status.save_path;
    snapshot.state = mapState(status.state);
    snapshot.progress = status.progress;
    snapshot.totalWanted = status.total_wanted;
    snapshot.totalWantedDone = status.total_wanted_done;
    snapshot.totalDownloaded = status.total_download;
    snapshot.totalUploaded = status.total_upload;
    snapshot.downloadRate = status.download_rate;
    snapshot.uploadRate = status.upload_rate;
    snapshot.numPeers = status.num_peers;
    snapshot.numSeeds = status.num_seeds;
    snapshot.isPaused = bool(status.flags & lt::torrent_flags::paused);
    snapshot.isSequential =
        bool(status.flags & lt::torrent_flags::sequential_download);
    snapshot.isFinished = status.is_finished;
    snapshot.isSeeding = status.is_seeding;
    snapshot.hasMetadata = status.has_metadata;
    snapshot.errorMessage = status.errc ? status.errc.message() : std::string();
    return snapshot;
}

Alert makeAlert(AlertKind kind, std::string infoHash, std::string message) {
    Alert alert;
    alert.kind = kind;
    alert.infoHash = std::move(infoHash);
    alert.message = std::move(message);
    alert.hasSnapshot = false;
    return alert;
}

} // namespace

struct Session::Impl {
    /// Guards the lifetime of `session` against the alert pump.
    ///
    /// The pump blocks inside waitAndDrainAlerts for up to a quarter second at
    /// a time while shutdown() destroys the session; without this, shutdown
    /// frees the object out from under a thread that is still dereferencing it.
    /// Readers take a shared lock (libtorrent's session is internally
    /// synchronised, so they may overlap); only shutdown takes it exclusively.
    std::shared_mutex sessionMutex;
    std::unique_ptr<lt::session> session;
    lt::session_proxy proxy;
    bool shuttingDown = false;
    std::atomic<int> refCount{1};
    /// libtorrent addresses torrents by handle, not hex string, so keep the
    /// mapping the Swift side works in.
    std::unordered_map<std::string, lt::torrent_handle> handles;
};

// MARK: - Lifetime

Session::Session(const SessionConfig &config) : m_impl(new Impl()) {
    lt::settings_pack settings;
    applyConfig(settings, config, /*includeStartupOnly=*/true);

    // Without an explicit mask libtorrent posts every alert category, which
    // floods the queue. Take the ones the client acts on.
    settings.set_int(lt::settings_pack::alert_mask,
                     lt::alert_category::status | lt::alert_category::error |
                         lt::alert_category::storage | lt::alert_category::tracker |
                         lt::alert_category::performance_warning);

    lt::session_params params(settings);
    if (config.usePosixDiskIO) {
        params.disk_io_constructor = lt::posix_disk_io_constructor;
    }

    // libtorrent attaches ut_pex, ut_metadata and smart_ban automatically. To
    // turn peer exchange off we have to opt out of that set and re-add the
    // other two by hand, since PEX is a plugin rather than a setting and so
    // cannot be toggled once the session is running.
    if (config.enablePEX) {
        m_impl->session = std::make_unique<lt::session>(std::move(params));
    } else {
        m_impl->session = std::make_unique<lt::session>(std::move(params),
                                                       lt::session_flags_t{});
        m_impl->session->add_extension(&lt::create_ut_metadata_plugin);
        m_impl->session->add_extension(&lt::create_smart_ban_plugin);
    }
}

Session::~Session() {
    try {
        shutdown();
    } catch (...) {
        // Never let an exception escape a destructor.
    }
    delete m_impl;
}

Session *sessionCreate(const SessionConfig &config) {
    try {
        return new Session(config);
    } catch (...) {
        return nullptr;
    }
}

void Session::shutdown() {
    try {
        std::unique_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (m_impl->shuttingDown || !m_impl->session) {
            return;
        }
        m_impl->shuttingDown = true;
        // abort() hands back a proxy whose destructor blocks until libtorrent's
        // asynchronous shutdown completes.
        m_impl->proxy = m_impl->session->abort();
        m_impl->session.reset();
        m_impl->handles.clear();
    } catch (...) {
    }
}

// MARK: - Alerts

std::vector<Alert> Session::waitAndDrainAlerts(std::int32_t timeoutMs) {
    std::vector<Alert> results;
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            results.push_back(makeAlert(AlertKind::sessionShutdown, {}, "session stopped"));
            return results;
        }

        m_impl->session->wait_for_alert(lt::milliseconds(timeoutMs));

        std::vector<lt::alert *> alerts;
        m_impl->session->pop_alerts(&alerts);

        for (lt::alert *raw : alerts) {
            if (auto *a = lt::alert_cast<lt::state_update_alert>(raw)) {
                // One libtorrent alert carries many statuses; fan them out so
                // Swift sees one event per torrent.
                for (const lt::torrent_status &status : a->status) {
                    Alert alert = makeAlert(AlertKind::stateUpdate,
                                            hexInfoHash(status.info_hashes), {});
                    alert.snapshot = makeSnapshot(status);
                    alert.hasSnapshot = true;
                    results.push_back(std::move(alert));
                }
            } else if (auto *a = lt::alert_cast<lt::add_torrent_alert>(raw)) {
                if (a->error) {
                    results.push_back(makeAlert(AlertKind::torrentErrored, {},
                                                a->error.message()));
                } else {
                    const lt::torrent_status status = a->handle.status();
                    const std::string hash = hexInfoHash(status.info_hashes);
                    m_impl->handles[hash] = a->handle;
                    Alert alert = makeAlert(AlertKind::torrentAdded, hash, status.name);
                    alert.snapshot = makeSnapshot(status);
                    alert.hasSnapshot = true;
                    results.push_back(std::move(alert));
                }
            } else if (auto *a = lt::alert_cast<lt::torrent_removed_alert>(raw)) {
                const std::string hash = hexInfoHash(a->info_hashes);
                m_impl->handles.erase(hash);
                results.push_back(makeAlert(AlertKind::torrentRemoved, hash, {}));
            } else if (auto *a = lt::alert_cast<lt::torrent_finished_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::torrentFinished,
                                            hexInfoHash(a->handle.info_hashes()), {}));
            } else if (auto *a = lt::alert_cast<lt::torrent_paused_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::torrentPaused,
                                            hexInfoHash(a->handle.info_hashes()), {}));
            } else if (auto *a = lt::alert_cast<lt::torrent_resumed_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::torrentResumed,
                                            hexInfoHash(a->handle.info_hashes()), {}));
            } else if (auto *a = lt::alert_cast<lt::torrent_checked_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::torrentChecked,
                                            hexInfoHash(a->handle.info_hashes()), {}));
            } else if (auto *a = lt::alert_cast<lt::metadata_received_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::metadataReceived,
                                            hexInfoHash(a->handle.info_hashes()), {}));
            } else if (auto *a = lt::alert_cast<lt::torrent_error_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::torrentErrored,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->error.message()));
            } else if (auto *a = lt::alert_cast<lt::tracker_error_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::trackerError,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->error.message()));
            } else if (auto *a = lt::alert_cast<lt::save_resume_data_alert>(raw)) {
                Alert alert = makeAlert(AlertKind::resumeDataSaved,
                                        hexInfoHash(a->handle.info_hashes()), {});
                const std::vector<char> buffer = lt::write_resume_data_buf(a->params);
                alert.resumeData.assign(buffer.begin(), buffer.end());
                static_assert(sizeof(char) == sizeof(std::uint8_t), "byte size mismatch");
                results.push_back(std::move(alert));
            } else if (auto *a = lt::alert_cast<lt::storage_moved_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::storageMoved,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->storage_path()));
            } else if (auto *a = lt::alert_cast<lt::storage_moved_failed_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::storageMoveFailed,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->error.message()));
            } else if (auto *a = lt::alert_cast<lt::file_renamed_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::contentRenamed,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->new_name()));
            } else if (auto *a = lt::alert_cast<lt::file_rename_failed_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::contentRenameFailed,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->error.message()));
            } else if (auto *a = lt::alert_cast<lt::save_resume_data_failed_alert>(raw)) {
                results.push_back(makeAlert(AlertKind::resumeDataFailed,
                                            hexInfoHash(a->handle.info_hashes()),
                                            a->error.message()));
            } else {
                // Preserved rather than dropped, so nothing goes missing silently.
                results.push_back(makeAlert(AlertKind::unknown, {}, raw->message()));
            }
        }
    } catch (const std::exception &e) {
        results.push_back(makeAlert(AlertKind::unknown, {}, e.what()));
    } catch (...) {
        results.push_back(makeAlert(AlertKind::unknown, {}, "unknown C++ exception"));
    }
    return results;
}

// MARK: - Adding torrents

AddResult Session::addMagnet(const std::string &uri, const std::string &savePath) {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            return AddResult{false, "session stopped", {}};
        }
        lt::add_torrent_params params = lt::parse_magnet_uri(uri);
        params.save_path = savePath;
        const lt::torrent_handle handle = m_impl->session->add_torrent(std::move(params));
        const std::string hash = hexInfoHash(handle.info_hashes());
        m_impl->handles[hash] = handle;
        return AddResult{true, {}, hash};
    } catch (const std::exception &e) {
        return AddResult{false, e.what(), {}};
    } catch (...) {
        return AddResult{false, "unknown C++ exception", {}};
    }
}

AddResult Session::addTorrentFile(const std::string &path, const std::string &savePath) {
    return addTorrentFileWithResume(path, savePath, ByteBuffer());
}

AddResult Session::addTorrentFileWithResume(const std::string &path,
                                            const std::string &savePath,
                                            const ByteBuffer &resumeData) {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            return AddResult{false, "session stopped", {}};
        }
        lt::add_torrent_params params;
        if (!resumeData.empty()) {
            // Resume data carries the save path and file priorities, so parse it
            // first and let the explicit arguments below win.
            params = lt::read_resume_data(
                {reinterpret_cast<const char *>(resumeData.data()),
                 static_cast<std::ptrdiff_t>(resumeData.size())});
        }
        params.ti = std::make_shared<lt::torrent_info>(path);
        params.save_path = savePath;
        const lt::torrent_handle handle = m_impl->session->add_torrent(std::move(params));
        const std::string hash = hexInfoHash(handle.info_hashes());
        m_impl->handles[hash] = handle;
        return AddResult{true, {}, hash};
    } catch (const std::exception &e) {
        return AddResult{false, e.what(), {}};
    } catch (...) {
        return AddResult{false, "unknown C++ exception", {}};
    }
}

AddResult Session::addFromResumeData(const ByteBuffer &resumeData,
                                     const std::string &savePath) {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            return AddResult{false, "session stopped", {}};
        }
        if (resumeData.empty()) {
            return AddResult{false, "empty resume data", {}};
        }
        lt::add_torrent_params params = lt::read_resume_data(
            {reinterpret_cast<const char *>(resumeData.data()),
             static_cast<std::ptrdiff_t>(resumeData.size())});
        if (!savePath.empty()) {
            params.save_path = savePath;
        }
        const lt::torrent_handle handle = m_impl->session->add_torrent(std::move(params));
        const std::string hash = hexInfoHash(handle.info_hashes());
        m_impl->handles[hash] = handle;
        return AddResult{true, {}, hash};
    } catch (const std::exception &e) {
        return AddResult{false, e.what(), {}};
    } catch (...) {
        return AddResult{false, "unknown C++ exception", {}};
    }
}

// MARK: - Torrent operations

namespace {

/// Shared shape for the operations that just look up a handle and act on it.
template <typename Body>
Result withHandle(std::unordered_map<std::string, lt::torrent_handle> &handles,
                  const std::string &infoHash, Body body) {
    try {
        const auto it = handles.find(infoHash);
        if (it == handles.end() || !it->second.is_valid()) {
            return Result{false, "no such torrent: " + infoHash};
        }
        body(it->second);
        return Result{true, {}};
    } catch (const std::exception &e) {
        return Result{false, e.what()};
    } catch (...) {
        return Result{false, "unknown C++ exception"};
    }
}

} // namespace

Result Session::removeTorrent(const std::string &infoHash, bool deleteFiles) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    if (!m_impl->session) {
        return Result{false, "session stopped"};
    }
    lt::session *session = m_impl->session.get();
    Result result = withHandle(m_impl->handles, infoHash,
                               [session, deleteFiles](const lt::torrent_handle &handle) {
                                   session->remove_torrent(
                                       handle, deleteFiles ? lt::session::delete_files
                                                           : lt::remove_flags_t{});
                               });
    if (result.ok) {
        m_impl->handles.erase(infoHash);
    }
    return result;
}

Result Session::pauseTorrent(const std::string &infoHash) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash, [](const lt::torrent_handle &handle) {
        // Clearing auto_managed stops libtorrent's queue from resuming it.
        handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.pause();
    });
}

Result Session::resumeTorrent(const std::string &infoHash) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash, [](const lt::torrent_handle &handle) {
        handle.set_flags(lt::torrent_flags::auto_managed);
        handle.resume();
    });
}

Result Session::recheckTorrent(const std::string &infoHash) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [](const lt::torrent_handle &handle) { handle.force_recheck(); });
}

Result Session::reannounceTorrent(const std::string &infoHash) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash, [](const lt::torrent_handle &handle) {
        handle.force_reannounce();
    });
}

Result Session::moveStorage(const std::string &infoHash, const std::string &newPath) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [&newPath](const lt::torrent_handle &handle) {
                          handle.move_storage(newPath);
                      });
}

Result Session::renameContent(const std::string &infoHash, const std::string &newName) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);

    // Reject anything that could escape the save path. libtorrent sanitises
    // too, but a rejected rename with a clear reason beats a silently mangled
    // one.
    if (newName.empty() || newName == "." || newName == ".."
        || newName.find('/') != std::string::npos
        || newName.find('\\') != std::string::npos) {
        return Result{false, "A name cannot be empty or contain path separators."};
    }

    return withHandle(m_impl->handles, infoHash,
                      [&newName](const lt::torrent_handle &handle) {
        const std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info) {
            return;  // no metadata yet; nothing to rename
        }
        const lt::file_storage &storage = info->files();

        // A single-file torrent has no containing folder, so the file itself is
        // what carries the name.
        if (storage.num_files() == 1) {
            const std::string current = storage.file_path(lt::file_index_t{0});
            const std::size_t slash = current.find_last_of('/');
            const bool hasDirectory = slash != std::string::npos;

            // The extension has to survive, or the file stops being playable.
            // Note the npos handling: comparing `dot > slash` when there is no
            // slash compares against SIZE_MAX and is always false, which
            // silently dropped the extension for exactly the common case of a
            // single file at the root.
            const std::string extension = [&] {
                const std::size_t dot = current.find_last_of('.');
                if (dot == std::string::npos) {
                    return std::string();
                }
                if (hasDirectory && dot < slash) {
                    return std::string();  // the dot belongs to a directory name
                }
                return current.substr(dot);
            }();
            const std::string prefix =
                hasDirectory ? current.substr(0, slash + 1) : std::string();
            handle.rename_file(lt::file_index_t{0}, prefix + newName + extension);
            return;
        }

        // Multi-file: every path starts with the containing folder, so swap
        // that first component on each one.
        for (lt::file_index_t file : storage.file_range()) {
            const std::string path = storage.file_path(file);
            const std::size_t slash = path.find('/');
            if (slash == std::string::npos) {
                continue;  // not under the folder; leave it alone
            }
            handle.rename_file(file, newName + path.substr(slash));
        }
    });
}

Result Session::setTorrentLimits(const std::string &infoHash, std::int32_t downloadLimit,
                                 std::int32_t uploadLimit) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [downloadLimit, uploadLimit](const lt::torrent_handle &handle) {
                          handle.set_download_limit(downloadLimit);
                          handle.set_upload_limit(uploadLimit);
                      });
}

Result Session::setSequentialDownload(const std::string &infoHash, bool sequential) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [sequential](const lt::torrent_handle &handle) {
                          if (sequential) {
                              handle.set_flags(lt::torrent_flags::sequential_download);
                          } else {
                              handle.unset_flags(lt::torrent_flags::sequential_download);
                          }
                      });
}

namespace {

/// The pieces covering the first and last `window` bytes of `file`.
///
/// A window rather than a single piece at each end: one piece is often smaller
/// than a container's header, and players routinely read a little more than the
/// first few bytes before they will commit.
std::vector<lt::piece_index_t> endPieces(const lt::file_storage &storage,
                                         lt::file_index_t file,
                                         std::int64_t window) {
    std::vector<lt::piece_index_t> pieces;
    const std::int64_t size = storage.file_size(file);
    if (size <= 0) {
        return pieces;
    }
    const std::int64_t span = std::min(window, size);

    const lt::peer_request head = storage.map_file(file, 0, int(span));
    const lt::peer_request tail = storage.map_file(file, size - span, int(span));

    // map_file gives the first piece of the range and its byte length, so walk
    // forward far enough to cover the whole window.
    const int pieceLength = storage.piece_length();
    const int headCount = int((span + pieceLength - 1) / pieceLength);
    const int tailCount = headCount;

    for (int offset = 0; offset < headCount; ++offset) {
        const int index = int(head.piece) + offset;
        if (index < storage.num_pieces()) {
            pieces.push_back(lt::piece_index_t{index});
        }
    }
    for (int offset = 0; offset < tailCount; ++offset) {
        const int index = int(tail.piece) + offset;
        if (index < storage.num_pieces()) {
            pieces.push_back(lt::piece_index_t{index});
        }
    }
    return pieces;
}

} // namespace

Result Session::setFirstLastPiecePriority(const std::string &infoHash, bool enabled) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [enabled](const lt::torrent_handle &handle) {
        const std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info) {
            // A magnet with no metadata yet; the caller reapplies once it lands.
            return;
        }
        const lt::file_storage &storage = info->files();
        const std::vector<lt::download_priority_t> filePriorities =
            handle.get_file_priorities();

        // A megabyte at each end comfortably covers container headers and
        // indexes without pulling in so much that ordinary downloading suffers.
        const std::int64_t window = 1024 * 1024;
        const lt::download_priority_t level =
            enabled ? lt::top_priority : lt::default_priority;

        for (lt::file_index_t file : storage.file_range()) {
            const int index = int(file);
            // Skip files the user deselected; prioritising their ends would
            // start downloading data that was explicitly not wanted.
            if (index < int(filePriorities.size())
                && filePriorities[std::size_t(index)] == lt::dont_download) {
                continue;
            }
            for (lt::piece_index_t piece : endPieces(storage, file, window)) {
                handle.piece_priority(piece, level);
            }
        }
    });
}

bool Session::hasFirstLastPiecePriority(const std::string &infoHash) {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        const auto it = m_impl->handles.find(infoHash);
        if (it == m_impl->handles.end() || !it->second.is_valid()) {
            return false;
        }
        const std::shared_ptr<const lt::torrent_info> info = it->second.torrent_file();
        if (!info) {
            return false;
        }
        const lt::file_storage &storage = info->files();
        const std::vector<lt::download_priority_t> filePriorities =
            it->second.get_file_priorities();

        for (lt::file_index_t file : storage.file_range()) {
            const int index = int(file);
            if (index < int(filePriorities.size())
                && filePriorities[std::size_t(index)] == lt::dont_download) {
                continue;
            }
            const std::vector<lt::piece_index_t> pieces =
                endPieces(storage, file, 1024 * 1024);
            if (pieces.empty()) {
                continue;
            }
            // Checking the first wanted file is enough: the setting is applied
            // to every file at once, so they agree.
            return it->second.piece_priority(pieces.front()) == lt::top_priority;
        }
        return false;
    } catch (...) {
        return false;
    }
}

Result Session::setQueuePosition(const std::string &infoHash, std::int32_t position) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [position](const lt::torrent_handle &handle) {
                          handle.queue_position_set(lt::queue_position_t{position});
                      });
}

std::vector<FileEntry> Session::listFiles(const std::string &infoHash) {
    std::vector<FileEntry> entries;
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        const auto it = m_impl->handles.find(infoHash);
        if (it == m_impl->handles.end() || !it->second.is_valid()) {
            return entries;
        }
        const std::shared_ptr<const lt::torrent_info> info = it->second.torrent_file();
        if (!info) {
            // Magnet links have no metadata until peers supply it.
            return entries;
        }
        const lt::file_storage &storage = info->files();
        const std::vector<std::int64_t> progress = [&] {
            std::vector<std::int64_t> values;
            it->second.file_progress(values);
            return values;
        }();
        const std::vector<lt::download_priority_t> priorities =
            it->second.get_file_priorities();

        for (lt::file_index_t index : storage.file_range()) {
            const int raw = static_cast<int>(index);
            FileEntry entry;
            entry.index = raw;
            entry.path = storage.file_path(index);
            entry.size = storage.file_size(index);
            entry.downloaded =
                raw < static_cast<int>(progress.size()) ? progress[std::size_t(raw)] : 0;
            const int priority =
                raw < static_cast<int>(priorities.size())
                    ? static_cast<int>(priorities[std::size_t(raw)])
                    : 4;
            entry.priority = priority == 0   ? Priority::skip
                             : priority <= 1 ? Priority::low
                             : priority >= 7 ? Priority::high
                                             : Priority::normal;
            entries.push_back(std::move(entry));
        }
    } catch (...) {
    }
    return entries;
}

Result Session::setFilePriority(const std::string &infoHash, std::int32_t fileIndex,
                                Priority priority) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [fileIndex, priority](const lt::torrent_handle &handle) {
                          handle.file_priority(
                              lt::file_index_t{fileIndex},
                              lt::download_priority_t(static_cast<std::uint8_t>(priority)));
                      });
}

Result Session::setPieceDeadline(const std::string &infoHash, std::int32_t pieceIndex,
                                 std::int32_t deadlineMs) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [pieceIndex, deadlineMs](const lt::torrent_handle &handle) {
                          handle.set_piece_deadline(lt::piece_index_t{pieceIndex},
                                                    deadlineMs);
                      });
}

Result Session::clearPieceDeadlines(const std::string &infoHash) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash, [](const lt::torrent_handle &handle) {
        handle.clear_piece_deadlines();
    });
}

FileLocation Session::locateFile(const std::string &infoHash, std::int32_t fileIndex) {
    FileLocation location{-1, -1, -1, -1, -1, {}};
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        const auto it = m_impl->handles.find(infoHash);
        if (it == m_impl->handles.end() || !it->second.is_valid()) {
            return location;
        }
        const std::shared_ptr<const lt::torrent_info> info = it->second.torrent_file();
        if (!info) {
            return location;
        }
        const lt::file_storage &storage = info->files();
        const lt::file_index_t index{fileIndex};
        if (fileIndex < 0 || fileIndex >= storage.num_files()) {
            return location;
        }
        const std::int64_t offset = storage.file_offset(index);
        const std::int64_t size = storage.file_size(index);
        const std::int32_t pieceLength = storage.piece_length();

        location.offset = offset;
        location.size = size;
        location.pieceLength = pieceLength;
        location.firstPiece = static_cast<std::int32_t>(offset / pieceLength);
        // An empty file occupies no pieces; clamp so lastPiece is never before
        // firstPiece.
        location.lastPiece = size > 0
            ? static_cast<std::int32_t>((offset + size - 1) / pieceLength)
            : location.firstPiece;
        location.path = it->second.status(lt::torrent_handle::query_save_path).save_path +
                        "/" + storage.file_path(index);
    } catch (...) {
    }
    return location;
}

std::vector<PeerEntry> Session::listPeers(const std::string &infoHash) {
    std::vector<PeerEntry> entries;
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        const auto it = m_impl->handles.find(infoHash);
        if (it == m_impl->handles.end() || !it->second.is_valid()) {
            return entries;
        }
        std::vector<lt::peer_info> peers;
        it->second.get_peer_info(peers);
        for (const lt::peer_info &peer : peers) {
            PeerEntry entry;
            entry.address = peer.ip.address().to_string();
            entry.port = peer.ip.port();
            entry.client = peer.client;
            entry.downloadRate = peer.down_speed;
            entry.uploadRate = peer.up_speed;
            entry.progress = peer.progress;
            entry.isSeed = bool(peer.flags & lt::peer_info::seed);
            entry.isEncrypted = bool(peer.flags & lt::peer_info::rc4_encrypted) ||
                                bool(peer.flags & lt::peer_info::plaintext_encrypted);
            entries.push_back(std::move(entry));
        }
    } catch (...) {
    }
    return entries;
}

std::vector<TrackerEntry> Session::listTrackers(const std::string &infoHash) {
    std::vector<TrackerEntry> entries;
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        const auto it = m_impl->handles.find(infoHash);
        if (it == m_impl->handles.end() || !it->second.is_valid()) {
            return entries;
        }
        for (const lt::announce_entry &tracker : it->second.trackers()) {
            TrackerEntry entry;
            entry.url = tracker.url;
            entry.tier = tracker.tier;
            entry.isWorking = false;
            entry.isVerified = tracker.verified;
            entry.peerCount = 0;
            // An announce_entry holds one endpoint per listen socket; treat the
            // tracker as working if any of them succeeded.
            for (const lt::announce_endpoint &endpoint : tracker.endpoints) {
                for (const lt::announce_infohash &hash : endpoint.info_hashes) {
                    if (hash.last_error) {
                        entry.lastError = hash.last_error.message();
                    } else if (hash.start_sent || hash.complete_sent) {
                        entry.isWorking = true;
                    }
                    entry.peerCount = std::max(entry.peerCount, hash.scrape_complete);
                }
            }
            entries.push_back(std::move(entry));
        }
    } catch (...) {
    }
    return entries;
}

ByteBuffer Session::pieceAvailability(const std::string &infoHash) {
    ByteBuffer pieces;
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        const auto it = m_impl->handles.find(infoHash);
        if (it == m_impl->handles.end() || !it->second.is_valid()) {
            return pieces;
        }
        const lt::torrent_status status = it->second.status(lt::torrent_handle::query_pieces);
        pieces.reserve(std::size_t(status.pieces.size()));
        for (lt::piece_index_t index : status.pieces.range()) {
            pieces.push_back(status.pieces[index] ? 1 : 0);
        }
    } catch (...) {
    }
    return pieces;
}

Result Session::applySettings(const SessionConfig &config) {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            return Result{false, "session stopped"};
        }
        lt::settings_pack settings;
        applyConfig(settings, config, /*includeStartupOnly=*/false);
        m_impl->session->apply_settings(std::move(settings));
        return Result{true, {}};
    } catch (const std::exception &e) {
        return Result{false, e.what()};
    } catch (...) {
        return Result{false, "unknown C++ exception"};
    }
}

Result Session::setBlockedRanges(const StringList &cidrRanges) {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            return Result{false, "session stopped"};
        }
        lt::ip_filter filter;
        for (const std::string &range : cidrRanges) {
            const std::size_t slash = range.find('/');
            if (slash == std::string::npos) {
                return Result{false, "not CIDR notation: " + range};
            }
            lt::error_code ec;
            const lt::address base = lt::make_address(range.substr(0, slash), ec);
            if (ec) {
                return Result{false, "bad address in " + range};
            }
            const int prefix = std::stoi(range.substr(slash + 1));
            // Expand the prefix into the inclusive first/last pair libtorrent
            // wants, for v4 and v6 alike.
            if (base.is_v4()) {
                const std::uint32_t bits = base.to_v4().to_uint();
                const std::uint32_t mask =
                    prefix == 0 ? 0u : (0xFFFFFFFFu << (32 - prefix));
                filter.add_rule(lt::make_address_v4(bits & mask),
                                lt::make_address_v4(bits | ~mask),
                                lt::ip_filter::blocked);
            } else {
                auto first = base.to_v6().to_bytes();
                auto last = first;
                for (int bit = prefix; bit < 128; ++bit) {
                    first[std::size_t(bit / 8)] &= ~(1 << (7 - bit % 8));
                    last[std::size_t(bit / 8)] |= (1 << (7 - bit % 8));
                }
                filter.add_rule(lt::address_v6(first), lt::address_v6(last),
                                lt::ip_filter::blocked);
            }
        }
        m_impl->session->set_ip_filter(std::move(filter));
        return Result{true, {}};
    } catch (const std::exception &e) {
        return Result{false, e.what()};
    } catch (...) {
        return Result{false, "unknown C++ exception"};
    }
}

void Session::requestStatusUpdates() {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (m_impl->session) {
            m_impl->session->post_torrent_updates();
        }
    } catch (...) {
    }
}

std::int32_t Session::requestResumeData() {
    std::int32_t requested = 0;
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        for (auto &entry : m_impl->handles) {
            const lt::torrent_handle &handle = entry.second;
            if (!handle.is_valid() || !handle.status().has_metadata) {
                continue;
            }
            handle.save_resume_data(lt::torrent_handle::save_info_dict);
            requested += 1;
        }
    } catch (...) {
    }
    return requested;
}

std::int32_t Session::listenPort() const {
    try {
        std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
        if (!m_impl->session) {
            return 0;
        }
        return static_cast<std::int32_t>(m_impl->session->listen_port());
    } catch (...) {
        return 0;
    }
}

Result Session::addPeer(const std::string &infoHash, const std::string &host,
                        std::int32_t port) {
    std::shared_lock<std::shared_mutex> lock(m_impl->sessionMutex);
    return withHandle(m_impl->handles, infoHash,
                      [&host, port](const lt::torrent_handle &handle) {
                          const lt::tcp::endpoint endpoint(
                              lt::make_address(host),
                              static_cast<unsigned short>(port));
                          handle.connect_peer(endpoint);
                      });
}

Result createTorrentFile(const std::string &contentPath, const std::string &outputPath,
                         std::int32_t pieceLength) {
    try {
        lt::file_storage storage;
        lt::add_files(storage, contentPath);
        if (storage.num_files() == 0) {
            return Result{false, "no files at " + contentPath};
        }

        // v1_only keeps the fixture simple: set_hash() alone suffices, with no
        // per-file v2 merkle hashes to compute.
        lt::create_torrent torrent(storage, pieceLength, lt::create_torrent::v1_only);

        // Hash every piece off disk. set_piece_hashes needs the parent of the
        // content, since file_storage paths are relative to it.
        const std::size_t slash = contentPath.find_last_of('/');
        const std::string parent =
            slash == std::string::npos ? std::string(".") : contentPath.substr(0, slash);
        lt::set_piece_hashes(torrent, parent);

        const std::vector<char> buffer = torrent.generate_buf();
        std::FILE *file = std::fopen(outputPath.c_str(), "wb");
        if (file == nullptr) {
            return Result{false, "could not open " + outputPath};
        }
        const std::size_t written =
            std::fwrite(buffer.data(), 1, buffer.size(), file);
        std::fclose(file);
        if (written != buffer.size()) {
            return Result{false, "short write to " + outputPath};
        }
        return Result{true, {}};
    } catch (const std::exception &e) {
        return Result{false, e.what()};
    } catch (...) {
        return Result{false, "unknown C++ exception"};
    }
}

// MARK: - Build information

std::string libtorrentVersion() {
    try {
        return std::string(LIBTORRENT_VERSION);
    } catch (...) {
        return std::string();
    }
}

std::string opensslVersion() {
    try {
        // A real call into libcrypto, not the OPENSSL_VERSION_TEXT macro.
        return std::string(OpenSSL_version(OPENSSL_VERSION_STRING));
    } catch (...) {
        return std::string();
    }
}

bool libtorrentHasSSL() {
#ifdef TORRENT_USE_OPENSSL
    return true;
#else
    return false;
#endif
}

Result torrentNameFromFile(const std::string &path, std::string &outName) {
    try {
        lt::torrent_info info(path);
        outName = info.name();
        return Result{true, std::string()};
    } catch (const std::exception &e) {
        return Result{false, std::string(e.what())};
    } catch (...) {
        return Result{false, std::string("unknown C++ exception")};
    }
}

} // namespace torrentbridge

// Defined at global scope to match the declarations in the header.
void torrentBridgeSessionRetain(torrentbridge::Session *session) {
    if (session != nullptr) {
        session->m_impl->refCount.fetch_add(1, std::memory_order_relaxed);
    }
}

void torrentBridgeSessionRelease(torrentbridge::Session *session) {
    if (session == nullptr) {
        return;
    }
    if (session->m_impl->refCount.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        delete session;
    }
}
