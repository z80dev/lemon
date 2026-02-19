# Lemon Documentation

This is the Mintlify documentation for [Lemon](https://github.com/z80dev/lemon) - a local-first AI assistant and coding agent system built on the BEAM.

## Development

Install the [Mintlify CLI](https://www.npmjs.com/package/mintlify):

```bash
npm i -g mintlify
```

Run the dev server:

```bash
mintlify dev
```

The documentation will be available at `http://localhost:3000`.

## Structure

```
mintlify-docs/
├── mint.json           # Mintlify configuration
├── introduction.mdx    # Landing page
├── quickstart.mdx      # Quick start guide
├── installation.mdx    # Installation instructions
├── docs/               # Documentation
│   ├── why-beam.mdx
│   ├── architecture-overview.mdx
│   ├── project-structure.mdx
│   ├── components/     # Component docs
│   ├── clients/        # Client docs
│   ├── config/         # Configuration docs
│   └── advanced/       # Advanced topics
├── api/                # API reference
│   ├── overview.mdx
│   ├── methods.mdx
│   └── events.mdx
├── architecture/       # Architecture deep dive
│   ├── beam-patterns.mdx
│   ├── supervision.mdx
│   ├── event-bus.mdx
│   └── tool-execution.mdx
├── logo/               # Logo files
└── images/             # Image assets
```

## Deployment

To deploy to Mintlify:

1. Push this directory to a GitHub repository
2. Connect the repo to [Mintlify](https://mintlify.com)
3. Deploy!

## Contributing

Documentation improvements are welcome! Please submit PRs to the main Lemon repository.
