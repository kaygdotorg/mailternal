/// Session-layer IMAP client for Mailternal 0.0.1.
///
/// Speaks IMAP4rev1 (and the extensions in `docs/spec/sync.md`) over NIO + NIOIMAP.
/// No storage, no MIME parsing, no sync policy — those belong to the wave-2 engine.
///
/// The public surface is ``IMAPSession`` plus the supporting value types in this module.
/// A non-peek body fetch cannot be expressed: ``IMAPFetchRequest/peek`` only carries
/// ``IMAPPeekSection`` values, which always encode as `BODY.PEEK` / `BINARY.PEEK`.
enum MailternalIMAPModuleDocs {}
