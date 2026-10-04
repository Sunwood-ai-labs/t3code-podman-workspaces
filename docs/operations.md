# T3 Code 運用手順

この構成は Linux の rootless Podman 5.x、cgroup v2、systemd user manager を使います。各ユーザーの `t3code-<user>` コンテナは専用の `t3code-<user>` ネットワークにだけ参加し、ホストポートを公開しません。Caddy は各ネットワークに参加して `t3code-<user>:3773` へ接続します。

`users.conf` と `config.env` が構成の入力です。ユーザー名は小文字英字または数字で始まり、小文字英数字とハイフンだけを使います。`caddy` は共有プロキシ用に予約されています。また、`alice` と `alice-network` のように Quadlet のサービス名が重なる組み合わせは使えません。`users.conf` の空行と、先頭の空白を除いて `#` で始まる行は無視されます。

## 初回セットアップ

1. Linux ホストに rootless Podman 5.x、systemd user manager、cgroup v2 を用意します。確認例:

   ```bash
   podman --version
   podman info --format '{{.Host.CgroupsVersion}}'
   systemctl --user is-system-running
   ```

2. 社内 DNS で `user1.<T3_DOMAIN>` などを Caddy ホストへ向け、Caddy が HTTPS 用証明書を取得できるようにします。`config.env` の `T3_DOMAIN`、`CADDY_HTTP_PORT`、`CADDY_HTTPS_PORT` が実際の公開設定と一致していることを確認します。

3. 担当 A の `scripts/build-image.sh` で `config.env` の `T3_IMAGE` をビルドします。担当 C の `scripts/render-caddy.sh` が同じ `scripts/render.sh` 実行時に Caddy の Quadlet と Caddyfile を生成します。

4. リポジトリのルートで生成とインストールを行います。

   ```bash
   scripts/render.sh
   scripts/install.sh --dry-run
   scripts/install.sh
   ```

   `render.sh` は `build/quadlet/` と `build/caddy/Caddyfile` を更新します。`install.sh` は Quadlet を `~/.config/containers/systemd/` に配置し、Caddyfile を `~/.config/t3code/caddy/Caddyfile` に配置します。未作成のユーザー環境ファイルは空で作り、権限を `600` にします。ユーザー環境ファイルと名前付きボリュームはリポジトリ外にあります。

5. user manager をログアウト後も維持し、起動時から実行する必要がある場合は、管理者に次を依頼します。インストールスクリプトはこの設定を変更しません。

   ```bash
   loginctl enable-linger <Linuxユーザー名>
   ```

6. 起動状態を確認します。

   ```bash
   scripts/status.sh
   systemctl --user status t3code-user1.service
   podman network ls
   ```

## ユーザーの追加と削除

### 追加

`users.conf` に新しいユーザー名を 1 行追加し、次を実行します。

```bash
scripts/render.sh
scripts/install.sh
```

インストール時に `~/.config/t3code/<user>.env` が作成されます。ユーザーの API キーを設定してからコンテナを再起動してください。既存ユーザーと Caddy の設定も再配置されます。

### 削除

1. `users.conf` から対象のユーザーを削除します。
2. `scripts/render.sh`、続けて `scripts/install.sh` を実行します。インストールスクリプトは古いユーザーのサービスを停止し、コンテナとネットワーク、Quadlet ファイルを削除します。ホーム、workspace、data の名前付きボリュームは残ります。
3. データも削除する場合は、次を実行します。スクリプトは対象ボリュームを表示した直後に削除します。実行前に対象ユーザーを確認してください。

   ```bash
   scripts/uninstall.sh --user <user> --purge-volumes
   ```

   `--user` はすでに `users.conf` から削除され、Caddy の生成済みユニットが対象ネットワークを参照していないユーザーに使います。ユーザー環境ファイルには API キーが残るため、不要なら別途安全に削除してください。

アプリ全体をアンインストールする場合は `scripts/uninstall.sh` を実行します。これは全てのインストール済み T3 Code/Caddy ユニットを停止・削除しますが、ボリュームとユーザー環境ファイルは既定では残します。全ユーザーのボリュームも消す場合だけ `scripts/uninstall.sh --purge-volumes` を指定してください。

## ペアリング

ユーザーがログインできる状態で、対象ユーザーのペアリングリンクを発行します。

```bash
scripts/pair.sh user1 --ttl 15m
```

既定 TTL は `15m` です。公開 URL は `https://<user>.<T3_DOMAIN>:<CADDY_HTTPS_PORT>` で、HTTPS ポートが `443` の場合はポート番号を省略します。リンクは有効期限内に対象ユーザーへ安全な手段で渡してください。

## API キー

環境変数名は、T3 Code 内で利用するプロバイダー CLI が認識する名前に合わせます。例えばファイルを編集して必要な変数を記載します。

```bash
umask 077
${EDITOR:-vi} ~/.config/t3code/user1.env
chmod 600 ~/.config/t3code/user1.env
```

環境ファイルには `NAME=value` 形式で必要なキーを記載します。`export` は付けません。秘密情報は `config.env`、`users.conf`、Quadlet ファイル、リポジトリへ書かないでください。値を更新した後は対象コンテナを再起動します。

```bash
systemctl --user restart t3code-user1.service
```

## イメージ更新

担当 A のビルドスクリプトで同じ `T3_IMAGE` タグを再ビルドし、Quadlet と Caddy 設定を再生成・インストールします。

```bash
scripts/build-image.sh
scripts/render.sh
scripts/install.sh
```

インストールスクリプトは現在のユーザーサービスを再起動し、既存のイメージを使ってコンテナを作り直します。タグやリソース値を変える場合は `config.env` を更新したうえで再生成します。

## バックアップ

ユーザーごとに `t3code-<user>-home`、`t3code-<user>-workspace`、`t3code-<user>-data` の 3 ボリュームがあります。整合性のあるバックアップを取るには対象サービスを停止してからエクスポートし、完了後に再起動します。

```bash
user=user1
systemctl --user stop "t3code-${user}.service"
for volume in "t3code-${user}-home" "t3code-${user}-workspace" "t3code-${user}-data"; do
  podman volume export --output "${volume}-$(date +%F).tar" "$volume"
done
systemctl --user start "t3code-${user}.service"
```

アーカイブはアクセス制限されたバックアップ先に移し、復元手順も本番データを使わない環境で確認してください。

## ワークスペースごとの既定テーマ

T3 Code はテーマをブラウザーの localStorage に保存し、サーバー側の設定を持ちません。どのワークスペースを開いているか見分けやすくするため、`config.env` の `T3_DEFAULT_THEMES` に並べたテーマを `users.conf` の順に割り当てます(ユーザー数のほうが多いときは先頭から繰り返します)。イメージの entrypoint が起動時に `index.html` へ 1 行のスクリプトを差し込み、テーマ未設定のブラウザーにだけ既定値を入れます。配色(ライト / ダーク)の既定は `T3_DEFAULT_APPEARANCE`(`system`、`light`、`dark`)で決めます。テーマごとの差はダークのほうがはっきり出るので、既定は `dark` です。利用者が Settings > Appearance で選んだテーマと配色が優先されます。

- 割り当てを変えたら `scripts/render.sh` と `scripts/install.sh` を再実行します。すでにテーマが保存されているブラウザーには反映されません。
- `users.conf` の途中にユーザーを追加・削除すると、後ろのユーザーの既定テーマがずれます。
- `T3_DEFAULT_THEMES` や `T3_DEFAULT_APPEARANCE` を空にすると、その項目は T3 Code 本来の既定のままになります。
- この仕組みは T3 Code 0.0.45 の `index.html` と localStorage のキー `t3code:theme`、`t3code:theme-appearance-mode` に依存します。バージョンを上げたら表示を確認してください。差し込みに失敗しても、サーバーは元の `index.html` で起動します。

## トラブルシュート

- **サービスが見つからない**: `scripts/render.sh` と `scripts/install.sh` を再実行し、`systemctl --user daemon-reload` のエラーを確認します。Quadlet の生成エラーは `journalctl --user -u podman-user-wait-network-online.service` も確認します。
- **Quadlet の構文を確認する**: Linux ホストでユニットを一時ディレクトリへコピーし、`QUADLET_UNIT_DIRS=<dir> /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun` を実行します。出力に `Loading source unit file` と生成された `.service` が表示され、エラーがないことを確認します。
- **コンテナ起動失敗**: `systemctl --user status t3code-user1.service`、`journalctl --user -u t3code-user1.service`、`podman logs t3code-user1` を確認します。イメージに `t3`、Node.js、`dev` (UID/GID 1000) があることと、`T3_IMAGE` がローカルに存在することを確認します。
- **Caddy から接続できない**: Caddy コンテナが各ユーザーのネットワークに参加していること、コンテナが `0.0.0.0:3773` で待ち受けていること、`t3code-<user>:3773` がコンテナ間 DNS で解決されることを確認します。ユーザーコンテナに `PublishPort=` が設定されていないことも確認します。
- **HTTPS や公開 URL の不一致**: DNS、証明書発行条件、ファイアウォール、および `CADDY_HTTPS_PORT` を確認します。公開リンクを作り直すときは `scripts/pair.sh <user>` を使います。
- **ネットワーク設定の変更が反映されない**: 既存の Podman ネットワークは `install.sh` を再実行しても作り直されません。`quadlet/t3code-user.network.in` を変えたとき(`isolate=strict` を含まない古い版からの更新を含む)は、`scripts/uninstall.sh` の後に `scripts/install.sh` を実行します。ボリュームは残ります。`podman network inspect t3code-<user> --format '{{json .Options}}'` で `isolate` が `strict` であることを確認します。
- **`systemctl --user --failed` に `podman healthcheck run` が残る**: 起動直後の最初のヘルスチェックは、サーバーが待ち受けを始める前に実行されて失敗します。コンテナが `healthy` になっていれば問題ありません。`systemctl --user reset-failed` で消せます。
- **再起動後にサービスが起動しない**: `loginctl show-user "$USER" -p Linger` を確認し、必要なら管理者へ linger 有効化を依頼します。
- **使用量を確認する**: `scripts/status.sh` はサービス状態、Podman コンテナ状態、稼働中コンテナの現在メモリ使用量を表示します。停止中または未作成のコンテナのメモリは `n/a` です。
