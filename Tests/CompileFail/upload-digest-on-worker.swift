// A completion handler that hashes the upload on the worker, holding every
// other request on it while the whole file is read. In a handler the digest
// is the one that hashes on the blocking pool, and it has to be awaited.
// expect-error: instance method 'digest' is unavailable from asynchronous contexts
import Garuda
import GarudaUploads

func routes(_ app: Application, store: FileUploadStore) {
    app.resumableUploads("/files", store: store) { upload in
        let digest = upload.digest()
        return Text("\(digest?.count ?? 0)")
    }
}
