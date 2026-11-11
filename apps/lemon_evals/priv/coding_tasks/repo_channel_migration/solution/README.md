# Harbor Dispatch

An offline outbound delivery planner. No network calls or packages are required.
Run `node --test tests/*.test.ts` on Node 22.23. Imports use .ts extensions.

## Configuration

`loadConfig({ channel: "email", batchSize: 25, sender: "harbor" })` accepts
only these three keys. Unknown keys produce `unsupported config key: <key>`.
Channels are email, sms, webhook; invalid values produce `channel must be email, sms or webhook`.
Batch size is an integer 1..100 (`batchSize must be an integer from 1 to 100`).
Sender is trimmed and must be nonempty (`sender must be nonempty`).
`tenantConfig(base, overrides)` merges and applies the same validation.
`serializeConfig` emits the three fields in channel, batchSize, sender order,
pretty-printed with two spaces and a trailing newline. readConfig/saveConfig use that format.
Environment names are HARBOR_CHANNEL, HARBOR_BATCH_SIZE, HARBOR_SENDER;
missing values use defaults. Unrelated environment variables are ignored.

## Delivery behavior

`message(id, recipient, text)` rejects empty fields. Destinations need an @ for email,
a + followed by 8..15 digits for sms, or https:// for webhook; failures are
`invalid <channel> destination`. Email bodies use `Subject: Harbor update` and a blank line.
SMS bodies are unchanged and fail over 160 characters (`sms text exceeds 160 characters`).
Webhooks encode exactly {id,text}. Envelopes contain id,destination,body,channel,sender.
`plan(config, messages)` returns {channel,retry,batches} in input order. SMS batches
are capped at 10; other channels use batchSize. Retry {attempts,delayMs} is email
{3,2000}, sms {2,5000}, webhook {5,1000}. `dispatch` returns flat ordered receipts
{id,channel,status:"queued",destination}. `metricKey(config,tenant)` is dispatch.<tenant>.<channel>.

`node scripts/dispatch.ts --channel sms --message hello` outputs receipt JSON
for cli-1. Optional --recipient overrides the channel-specific default destination.
Unknown flags fail with `unsupported flag: <flag>`; absent values fail with
`missing value for <flag>`. `node scripts/export-config.ts` prints environment config.
`bash scripts/local-demo.sh` demonstrates both commands. JSON in config/ is operational input.
