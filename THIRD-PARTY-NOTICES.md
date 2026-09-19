# Third-party notices

Skein's own source is under the PolyForm Strict License 1.0.0 (see
[LICENSE.md](LICENSE.md)). The components it builds against are not, and none
of them is redistributed by this repository — each is fetched at build time by
`Scripts/bootstrap.sh`, `Scripts/build-openssl.sh`, or Swift Package Manager.

| Component | Version | License | How it is obtained |
| --- | --- | --- | --- |
| [libtorrent](https://github.com/arvidn/libtorrent) | 2.0.14 | BSD-3-Clause | git submodule, compiled in-tree |
| [Boost](https://www.boost.org) | 1.92.0 | BSL-1.0 | headers downloaded by `bootstrap.sh` |
| [OpenSSL](https://www.openssl.org) | 3.5.8 | Apache-2.0 | built from source by `build-openssl.sh` |
| [VLCKit](https://code.videolan.org/videolan/VLCKit) | 4.0 (pinned by revision) | **LGPL-2.1** | Swift Package Manager |
| [FeedKit](https://github.com/nmdias/FeedKit) | 10.5.0 | MIT | Swift Package Manager |

Skein's license does not, and cannot, restrict your rights in any of these.
Where they conflict, the component's own license governs that component.

## Before distributing a build

Everything above assumes Skein is published as **source only**, which is what
this repository does. Nobody but the person building it ever receives a copy of
these components, so no obligation to redistribute them arises.

Shipping a compiled app — a `.app`, a release download, TestFlight, anything
where a binary reaches someone else — changes that, because the binary embeds
all of them. At minimum that means:

- **VLCKit is LGPL-2.1**, and this is the binding constraint. You must supply
  its license text and either its source or a written offer for it, keep it
  dynamically linked so a recipient can substitute their own build, and not
  restrict what they may do with that portion. A blanket no-redistribution term
  over the whole binary would contradict rights LGPL-2.1 grants them over
  VLCKit, so the two cannot simply be stacked. Replacing VLCKit with AVFoundation
  would remove the problem, at the cost of the formats AVFoundation will not
  open — which is most of what people stream.
- **libtorrent's BSD-3-Clause** requires reproducing its copyright notice and
  disclaimer in the documentation accompanying a binary distribution.
- **OpenSSL's Apache-2.0** requires carrying its `NOTICE` text.
- **Boost's BSL-1.0** requires the license notice for source distribution, and
  explicitly waives it for copies "solely in the form of machine-executable
  object code", so a compiled binary needs nothing.

None of this is legal advice. If a binary release matters, it is worth an
actual review rather than a table in a repository.
