# lemon_media

Media job capability driver for Lemon.

Owns `LemonMedia.MediaJobs`, `LemonMedia.MediaJobSupervisor`,
`LemonMedia.MediaJobWorker`, and the `mix lemon.media` task. It keeps the
existing `.lemon/media-*` paths and depends on `lemon_core`, `jason`, and
`phoenix_pubsub`.
