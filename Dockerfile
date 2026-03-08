# Harness CI Plugin: AI Code Quality Scanner
# Image: anandraiin3/harness-code-quality
#
# Build:  docker build -t anandraiin3/harness-code-quality:latest .
# Push:   docker push anandraiin3/harness-code-quality:latest
# Test locally:
#   docker run --rm \
#     -e PLUGIN_LLM_PROVIDER=openai \
#     -e PLUGIN_API_KEY=sk-... \
#     -e PLUGIN_MODEL=gpt-4o-mini \
#     -v $(pwd):/harness/src \
#     -e PLUGIN_SOURCE_DIR=/harness/src \
#     -e DRONE_OUTPUT=/tmp/output.env \
#     anandraiin3/harness-code-quality:latest

FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq

# Copy and configure entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
