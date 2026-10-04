# T3 Code workspace image

## イメージの内容

`image/Containerfile` は `node:24.15.0-bookworm-slim` をベースに、次を含むイメージを作ります。今回のビルドと実行確認は Linux amd64 です。

- `t3@0.0.45`
- Claude Code CLI `@anthropic-ai/claude-code@2.1.289`
- Codex CLI `@openai/codex@0.160.0`
- `git`、`openssh-client`、`curl`、`ca-certificates`、`ripgrep`
- T3 のネイティブ実行ファイル用 `libatomic1` と、シグナルを転送する `tini`

実行ユーザーは `dev` (uid/gid 1000)、`HOME=/home/dev` です。`/home/dev`、`/workspace`、`/data` はイメージ作成時に dev 所有で作成します。T3 は `T3CODE_HOME=/data/t3`、`T3_PORT=3773` で起動し、コンテナのポートは公開しません。Entrypoint は `tini -g` 配下で次を実行します。

```text
t3 serve --mode web --host 0.0.0.0 --port 3773 \
  --base-dir /data/t3 --auto-bootstrap-project-from-cwd /workspace
```

起動時、entrypoint は `T3_DEFAULT_THEME` と `T3_DEFAULT_APPEARANCE` が設定されていれば、T3 Code の `index.html` の先頭へ 1 行のスクリプトを差し込みます。テーマや配色が未設定のブラウザーにだけ既定値を入れるためのものです。そのため、イメージのビルド時に元の `index.html` を `index.html.orig` として残し、`index.html` だけを dev 所有にしています。仕組みと注意点は[運用手順](operations.md)の「ワークスペースごとの既定テーマ」を参照してください。

## ビルド

リポジトリの `config.env` から `T3_IMAGE` と `T3_VERSION` を読み込みます。Linux + rootless Podman のホストで実行してください。今回の実機ビルドでは `PODMAN_CONNECTION=t3code-lab bash scripts/build-image.sh` を実行しました。

```bash
bash scripts/build-image.sh
```

開発用の別 Podman 接続など、接続先を明示する場合:

```bash
PODMAN_CONNECTION=t3code-lab bash scripts/build-image.sh
```

`NODE_VERSION`、`CLAUDE_CODE_VERSION`、`CODEX_VERSION` は環境変数で上書きでき、既定値はそれぞれ `24.15.0`、`2.1.289`、`0.160.0` です。T3 のバージョンとイメージ名は共通設定の `T3_VERSION`、`T3_IMAGE` を使います。今回のビルド結果は `localhost/t3code-workspace:0.0.45`、イメージサイズ `1,257,848,833` bytes (約 1.17 GiB) でした。Claude Code と Codex の同梱ペイロードが大きいため、slim ベースでもイメージ全体は大きくなります。

## 実機検証

2026-10-04、Windows 11 上の Podman 5.8.3 で、この検証専用に作成した rootless Linux amd64 マシン `t3code-lab` を使いました。コマンドでは接続先を明示し、既定の接続は変更していません。

| 確認 | 実測結果 |
| --- | --- |
| ビルドと実行ユーザー | ビルド成功。`id` は `uid=1000(dev) gid=1000(dev)`、`t3 --version` は `t3 v0.0.45`。 |
| Claude / Codex CLI | dev ユーザーで `claude --version` が `2.1.289 (Claude Code)`、`codex --version` が `codex-cli 0.160.0`。 |
| 名前付きボリューム | `t3code-user1-home`、`t3code-user1-workspace`、`t3code-user1-data` を所定の3パスへマウント。各パスへの書き込み成功、所有者は uid/gid 1000。 |
| HTTP | コンテナ内から `curl http://127.0.0.1:3773/` を実行し HTTP 200、本文 19,493 bytes。ホストへのポート割り当ては `map[]`。 |
| ペアリング | `t3 auth pairing create --base-dir /data/t3 --base-url https://user1.t3.example.internal:8443 --ttl 20m --label image-restart-check` が成功し、`https://user1.t3.example.internal:8443/pair#token=<redacted>` 形式のリンクを出力。トークン値は記録・掲載していません。 |
| 認証 | 発行した一回限りのペアリング資格情報を `POST /api/auth/browser-session` に渡すと HTTP 200、`authenticated=true`。Cookie を付けた `GET /api/auth/session` も HTTP 200、`authenticated=true`。 |
| WebSocket | Cookie から `POST /api/auth/websocket-ticket` で ticket を発行し、`/ws?wsTicket=…&orchestrationProtocol=1` へ接続して WebSocket upgrade 成功。 |
| 再起動後の永続性 | `podman stop --time 10` は約 1.86 秒で終了 (exit 143)。同じコンテナを再起動後、認証セッションが有効で `/workspace` のプロジェクト1件を再取得。home/workspace の書き込みマーカーと `/data/t3/userdata/state.sqlite` も残存。 |
| アイドル時メモリ | リクエストなしで約25秒待った後、`podman stats --no-stream` は `264.7MB / 33.5GB`、PIDs 21。`podman top` のプロセス RSS 合計は約 361.9 MiB。Podman の cgroup 使用量と RSS 合計は計上方法が異なります。検証用コンテナには共通設定の memory/cpu 上限を付けていません。 |

自動プロジェクト作成フラグを付けてサーバーを起動しましたが、ブラウザーの Welcome フローは実行していません。Welcome フロー前の orchestration snapshot は `projects_count=0` でした。その後 `t3 project add ... /workspace` で作ったプロジェクトの再起動後の残存は確認済みです。**自動作成フラグによる初回作成自体は未検証**です。

## ペアリングとリバースプロキシ

以下は `t3@0.0.45` のコード確認とコンテナへの直接 HTTP/WebSocket リクエストに基づきます。Caddy 経由の HTTPS 試験は[結合テストの記録](integration-test.md)にあります。

- ペアリングリンクは `/pair#token=...` です。ブラウザーは fragment の資格情報を読み取り、履歴から除去した後、`GET /api/auth/session`、`POST /api/auth/browser-session` (`{"credential":"…"}`)、再度の session 確認を行います。`--base-url` は出力するリンクの URL を作る指定で、待受先や Origin allowlist の設定ではありません。ペアリング資格情報は既定5分で失効し、一回だけ使用できます。今回の確認では TTL を `20m` に指定しました。 [auth.ts](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/web/src/environments/primary/auth.ts) · [HTTP auth](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/auth/http.ts) · [CLI](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/cli/auth.ts)
- 通常のブラウザー WebSocket は同一 origin の `/ws` を使い、HTTP session cookie で認証します。v0.0.45 では `orchestrationProtocol=1` などのクエリが付きます。Bearer/DPoP クライアント向けには `POST /api/auth/websocket-ticket` で ticket を発行し、`/ws?wsTicket=…` に接続する経路もあります。今回の upgrade は ticket 経路で確認しました。 [接続 URL](https://github.com/pingdotgg/t3code/blob/v0.0.45/packages/client-runtime/src/connection/resolver.ts) · [ticket 認可](https://github.com/pingdotgg/t3code/blob/v0.0.45/packages/client-runtime/src/authorization/remote.ts)
- 発行される cookie は `HttpOnly`、`Path=/`、`SameSite=Lax`、有効期限ありで、コードは `Secure` と `Domain` を設定しません。実行時の `Set-Cookie` でも `Secure` / `Domain` はありませんでした。TLS 終端を Caddy に置き、HTTPS を強制してください。`Domain` がないため cookie は host-only で、ユーザーごとのサブドメイン分離に適します。
- 標準の pairing/session と `/ws` にはアプリケーション側の Host/Origin allowlist が見当たりません。直接リクエストでは forged `Host` / `Origin` を指定した `GET /api/auth/session` が HTTP 200 を返しました (これは未認証 session 状態を返す確認であり、別 origin からのブラウザー認証成功を意味しません)。ルート応答には `Access-Control-Allow-Origin: *` も観測しました。CORS を認証境界として扱わないでください。 [CORS/HTTP server](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/http.ts) · [environment auth](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/auth/EnvironmentAuth.ts)
- v0.0.45 の HTTP request URL 再構成は `Host` と完全一致の `X-Forwarded-Proto: https` を参照しますが、この処理には trusted-proxy 判定がありません。ここでは `X-Forwarded-Host` を参照せず、client IP も `X-Forwarded-For` ではなく socket address から取得します。Caddy は元の公開 `Host` を保持し、`X-Forwarded-Proto: https` を渡す構成にしてください。コンテナをユーザー専用の Podman network 内に閉じ、Caddy 以外から到達できないようにします。 [request handling](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/auth/EnvironmentAuth.ts) · [server URL handling](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/server.ts)
- ブラウザーが現在の origin から API と WebSocket URL を組み立てるため、`https://<user>.<domain>:<port>/` のようなユーザー別サブドメインのルート運用と整合します。パス prefix 運用は URL builder が `/` に戻すため未対応の可能性があり、未検証です。Caddy は通常の HTTP に加えて `/ws` の WebSocket upgrade を中継する必要があります。 [target URL builder](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/web/src/environments/primary/target.ts)
- サーバー起動ログには、別の初回 pairing URL/トークンも出力されることを確認しました。トークン値を含むため、コンテナログの閲覧権限を制限してください。`t3 serve --help` ではこの出力を止めるオプションを確認できませんでした。

## 制約と未検証

- このイメージ単体の検証では、Caddy の実構成、HTTPS 証明書、Caddy 経由の pairing/auth、ユーザー間のネットワーク分離を確認していません。これらは結合テストで確認しました。[結合テストの記録](integration-test.md)を参照してください。
- `Secure` cookie 属性がなく、アプリケーションに Host/Origin allowlist もありません。外部公開は HTTPS のみとし、アプリコンテナの直接公開を避けてください。
- 起動時の自動 Welcome/project bootstrap は未検証です。`t3 project add` で明示追加したプロジェクトと pairing session の restart 後の残存は確認しました。
- イメージは Podman Linux amd64 で確認しました。別アーキテクチャ、Linux 本番ホストでの Quadlet/systemd 起動、実際の Claude/Codex API 利用、Caddy の TLS 終端は未検証です。
- Node のタグはバージョン指定ですが digest 固定ではありません。各 npm 直依存は build arg で exact version を指定しています。
