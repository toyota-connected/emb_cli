import 'dart:io';

/// Run [body] while holding an exclusive advisory lock on [lockFile] (created
/// if absent), so concurrent CI jobs sharing one cache serialize on the same
/// entry. Advisory only on NFS — document a node-local `EMB_CACHE_DIR` on
/// shared-home clusters.
Future<T> withFileLock<T>(File lockFile, Future<T> Function() body) async {
  lockFile.parent.createSync(recursive: true);
  final raf = lockFile.openSync(mode: FileMode.write);
  await raf.lock(FileLock.blockingExclusive);
  try {
    return await body();
  } finally {
    try {
      await raf.unlock();
    } on Object {
      // Best-effort release; the OS drops the lock on close/exit regardless.
    }
    await raf.close();
  }
}
