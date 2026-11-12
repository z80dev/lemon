# Replay broker

The broker connects producers with in-process consumers. Consumers resume from a sequence cursor and have bounded queues; slow consumers are disconnected rather than blocking a producer. History and live delivery must form one ordered stream. Run `go test -race ./...`.
