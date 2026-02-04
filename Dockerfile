FROM alpine:3.20.3

RUN apk add --no-cache jq curl

RUN addgroup -g 1000 agent \
  && adduser -D -u 1000 -G agent agent

# Keep runtime entirely self-contained:
# - tools are vendored via git submodules under ./tools (no network fetch in Dockerfile)
# - runtime scripts live under ./runtime
COPY tools /tools
COPY runtime /runtime
COPY tasks /tasks
COPY policy /policy

RUN mkdir -p /work \
  && chown -R 1000:1000 /work \
  && chmod 0755 /work \
  && chmod +x /runtime/agent.sh

ENV PATH="/tools/kv/bin:/tools/jsonl:/tools/jd/bin:/tools/moltbox/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME="/work" \
  LANG="C" \
  LC_ALL="C" \
  TZ="UTC"

WORKDIR /work
USER 1000:1000

ENTRYPOINT ["/runtime/agent.sh"]
