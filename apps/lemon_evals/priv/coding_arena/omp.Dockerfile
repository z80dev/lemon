# omp trial image: the arena toolchains plus the published omp CLI.
#
#   docker build -f apps/lemon_evals/priv/coding_arena/omp.Dockerfile \
#     --build-arg OMP_VERSION=18.18.9 -t lemon-arena-omp apps/lemon_evals/priv/coding_arena
FROM lemon-arena-base

ARG OMP_VERSION
ENV BUN_INSTALL=/opt/bun
RUN test -n "$OMP_VERSION" && \
    curl -fsSL https://bun.sh/install | bash && \
    /opt/bun/bin/bun install -g "@oh-my-pi/pi-coding-agent@${OMP_VERSION}" && \
    chmod -R a+rX /opt/bun && \
    ln -s /opt/bun/bin/bun /usr/local/bin/bun && ln -s /opt/bun/bin/omp /usr/local/bin/omp
