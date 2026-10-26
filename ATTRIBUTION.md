# Attribution / 来源与署名

SayRoute is a renamed and substantially developed descendant of [lilong7676/doubao-murmur](https://github.com/lilong7676/doubao-murmur), not a claim of entirely independent origin. The original `Copyright (c) 2026 lilong7676` and MIT license remain verbatim in [LICENSE](LICENSE).

Devon Kong's changes can be traced in this repository's Git history. The following commits identify implementation work, not a legal finding that every line in a module is independently authored:

| Work | Evidence in repository history |
| --- | --- |
| Installed Doubao IME session integration | `dfe484b` |
| Route selection and UU compatibility timing | `5ea98e4`, `c5befc8`, `0c74fbf`, `87c0d91` |
| Remote clipboard/paste bridge and failure handling | `3a02350`, `5445221`, `32dcc97`, `d49d080` |
| Per-session paste orders, completion state machine | `ae867f3` |
| Physical right-Command stopping | `00acf43`, `ed24368` |
| Encrypted session recovery, balanced paste events, safer updater, pointer-based overlay | `7ce79a9` |

The application lifecycle/menu, hotkey handling, overlay and update scaffolding evolved from the original project. Renaming files does not remove that provenance. The SayRoute migration adds the selected brand, explicit preference import and reversible bridge installation; those changes are recorded in the SayRoute migration commit in this repository's history.

The brand mark was selected and supplied by Devon; the supplied reference is preserved in `docs/brand/sayroute-reference.png`. The high-resolution app master was prepared with the built-in image-generation tool from that reference; the menu-bar mark is drawn natively as a template image. This records asset provenance, not trademark clearance.

SayRoute does not claim ownership of the Doubao or NetEase names. Third-party applications and services have their own licenses and terms.

---

SayRoute 是从原项目继承并持续开发的产品，不能表述为完全无原代码来源。原作者版权和 MIT 正文完整保留。上表列出可核查的开发历史，不等于逐行著作权判定。更名不抹除继承的应用、热键、悬浮窗和更新框架来源。

附件标志由 Devon 指定；保留原图并记录高清资源的生成来源。未据此声称已完成商标注册或名称排他性核验。
