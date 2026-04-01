# php-my-admin-lambda-web-adapter

[phpmyadmin-with-basic-auth](https://github.com/7474/phpmyadmin-with-basic-auth) を [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) で動作させるための構成です。

## Usage

ベースイメージの設定に加えて以下の環境変数を指定することでBASIC認証を設定できます。

- `BACIC_AUTH_USER`
- `BACIC_AUTH_PASSWORD`

また `PMA_SSL` 環境変数に `1` を設定することでSSL/TLS設定を有効にしてサーバに接続するようになります。
PlanetScaleなどのDBaaSに接続する際に設定します。

コンテナは **8080** ポートでリッスンします (Lambda Web Adapter のデフォルトポート)。

## Architecture

```
CloudFront (CDN) → Lambda Function URL → Lambda (phpMyAdmin + Lambda Web Adapter)
```

- **Lambda Web Adapter**: Lambda 呼び出しを HTTP リクエストに変換してコンテナ内の Apache へ転送します。
- **CloudFront**: CDN として Lambda Function URL の前段に配置します。

## Directory Structure

- [`src/`](src/) - コンテナイメージのソース
  - [`Dockerfile`](src/Dockerfile) - Lambda Web Adapter を組み込んだ phpMyAdmin イメージ
  - [`basic-auth.conf`](src/basic-auth.conf) - Apache BASIC認証設定
  - [`config.user.inc.php`](src/config.user.inc.php) - phpMyAdmin SSL設定
  - [`docker-entrypoint-with-basic-auth.sh`](src/docker-entrypoint-with-basic-auth.sh) - エントリポイントスクリプト
  - [`docker-compose.yml`](src/docker-compose.yml) - ローカル開発用 docker-compose
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) - ECR Public へのイメージ Push ワークフロー
- [`ecr-terraform/`](ecr-terraform/) - ECR Public リポジトリと GitHub Actions OIDC ロールの Terraform
- [`example-terraform/`](example-terraform/) - Lambda + CloudFront デプロイ例の Terraform

## Setup

### 1. ECR Public リポジトリの作成

```bash
cd ecr-terraform
terraform init
terraform apply
```

`github_actions_role_arn` と `repository_uri` の出力値を控えておきます。

### 2. GitHub Secrets の設定

| Secret | 説明 |
|--------|------|
| `AWS_ROLE_ARN` | ecr-terraform で作成した GitHub Actions IAM ロール ARN |
| `ECR_PUBLIC_ALIAS` | ECR Public エイリアス (例: `g2g6t4l2`) |

### 3. イメージの Push

`main` ブランチへの push または `v*.*.*` タグの作成で自動的にイメージが ECR Public と GHCR へ Push されます。

### 4. Lambda へのデプロイ

```bash
cd example-terraform
terraform init
terraform apply \
  -var="image_uri=public.ecr.aws/<alias>/phpmyadmin-lambda-adapter:latest" \
  -var="basic_auth_password=<password>"
```

## Example

- [`src/docker-compose.yml`](src/docker-compose.yml): ローカル開発用 docker-compose の例
- [`example-terraform/`](example-terraform/): AWS Lambda + CloudFront にホスティングする Terraform コードの例
