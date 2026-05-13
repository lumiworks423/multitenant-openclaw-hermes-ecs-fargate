# ============================================================
# Cognito User Pool — OIDC Identity Provider
# Supports: email/password, Google, SAML federation
# ============================================================

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = { Name = "${var.project_name}-cognito" }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project_name}-${var.aws_region}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "workshop-app"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = true

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [
    "https://${aws_cloudfront_distribution.main.domain_name}/api/auth/oidc/callback",
  ]

  logout_urls = [
    "https://${aws_cloudfront_distribution.main.domain_name}/",
  ]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

# ============================================================
# SSM Parameters for Cognito (consumed by Provisioning Service)
# ============================================================

resource "aws_ssm_parameter" "cognito_user_pool_id" {
  name  = "/${var.project_name}/cognito-user-pool-id"
  type  = "String"
  value = aws_cognito_user_pool.main.id
}

resource "aws_ssm_parameter" "cognito_client_id" {
  name  = "/${var.project_name}/cognito-client-id"
  type  = "String"
  value = aws_cognito_user_pool_client.main.id
}

resource "aws_ssm_parameter" "cognito_client_secret" {
  name  = "/${var.project_name}/cognito-client-secret"
  type  = "SecureString"
  value = aws_cognito_user_pool_client.main.client_secret
}

resource "aws_ssm_parameter" "cognito_domain" {
  name  = "/${var.project_name}/cognito-domain"
  type  = "String"
  value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}
