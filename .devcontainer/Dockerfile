# See .devcontainer/Dockerfile.base and .github/workflows/publish_codespace.yml files.
FROM tryzealot/codespace:latest

COPY . /workspace

USER root
RUN chown -R vscode:vscode /workspace
USER vscode

RUN bundle install && pnpm install
