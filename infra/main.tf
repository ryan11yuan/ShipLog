terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # No backend block: state is a local file. A team would add backend "azurerm"
  # (state in a storage account, locked with a blob lease, access via RBAC).
}

provider "azurerm" {
  features {
    storage {
      # Manage storage only through Azure Resource Manager, never the data plane,
      # so Terraform works with account keys disabled
      data_plane_available = false
    }
  }
  subscription_id = var.subscription_id
  # We registered exactly the providers we need with the az CLI
  resource_provider_registrations = "none"
}

# Who is running Terraform (tenant ID and your user's object ID)
data "azurerm_client_config" "current" {}

locals {
  tags = {
    project = "shiplog"
    env     = var.env
    owner   = var.owner
  }
}

# Registry, storage and vault names must be unique across all of Azure
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---------- Platform ----------

resource "azurerm_resource_group" "main" {
  name     = "rg-shiplog-${var.env}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_container_registry" "main" {
  name                = "acrshiplog${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false # no shared username/password; pulls and pushes use Entra ID
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-shiplog-${var.env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.5 # hard cap on ingestion, so a log flood can't run up a bill
  tags                = local.tags
}

resource "azurerm_container_app_environment" "main" {
  name                       = "cae-shiplog-${var.env}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.tags

  # Azure adds this serverless profile to every new environment. Declaring it
  # stops Terraform from trying to remove it on every plan.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# ---------- Data and secrets ----------

resource "azurerm_storage_account" "main" {
  name                     = "stshiplog${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  # Must stay true: Azure's table-management API uses the account key internally,
  # so creating the table fails with a 403 when keys are off. The app never uses
  # the key; it authenticates with its managed identity.
  shared_access_key_enabled = true
  tags                      = local.tags
}

resource "azurerm_storage_table" "deploys" {
  name               = "deploys"
  storage_account_id = azurerm_storage_account.main.id
}

resource "azurerm_key_vault" "main" {
  name                       = "kv-shiplog-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true  # access via Azure roles, not vault access policies
  purge_protection_enabled   = false # lets teardown delete it completely; a bank would enable it
  soft_delete_retention_days = 7
  tags                       = local.tags
}

# Being subscription Owner doesn't grant access to secrets in an RBAC vault,
# so the person running Terraform needs this to write the secret below
resource "azurerm_role_assignment" "me_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "api_key" {
  length  = 40
  special = false # safe to send in an HTTP header without escaping
}

resource "azurerm_key_vault_secret" "api_key" {
  name         = "shiplog-api-key"
  value        = random_password.api_key.result
  key_vault_id = azurerm_key_vault.main.id
  tags         = local.tags
  depends_on   = [azurerm_role_assignment.me_kv_secrets_officer]
}

# ---------- App identity and its permissions ----------

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-shiplog-app"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Scoped to the one secret, not the whole vault
resource "azurerm_role_assignment" "app_kv_secret_user" {
  scope                = "${azurerm_key_vault.main.id}/secrets/${azurerm_key_vault_secret.api_key.name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Scoped to the one table, not the whole storage account
resource "azurerm_role_assignment" "app_table_data" {
  scope                = "${azurerm_storage_account.main.id}/tableServices/default/tables/${azurerm_storage_table.deploys.name}"
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# ---------- The app ----------

resource "azurerm_container_app" "main" {
  name                         = "ca-shiplog-${var.env}"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption" # the serverless profile declared on the environment
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Pull from our registry using the app identity (needs AcrPull above)
  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0 # scale to zero when idle: no traffic, no cost
    max_replicas = 1

    container {
      name   = "shiplog"
      image  = "mcr.microsoft.com/k8se/quickstart:latest" # placeholder until Jenkins deploys
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "AZURE_CLIENT_ID" # tells DefaultAzureCredential which identity to use
        value = azurerm_user_assigned_identity.app.client_id
      }
      env {
        name  = "KEY_VAULT_URL"
        value = azurerm_key_vault.main.vault_uri
      }
      env {
        name  = "TABLE_ENDPOINT"
        value = azurerm_storage_account.main.primary_table_endpoint
      }
      env {
        name  = "TABLE_NAME"
        value = azurerm_storage_table.deploys.name
      }
    }
  }

  lifecycle {
    # Jenkins owns the image tag. Without this, every terraform apply would
    # roll the app back to the placeholder.
    ignore_changes = [template[0].container[0].image]
  }

  # Permissions must exist before the first revision starts
  depends_on = [
    azurerm_role_assignment.app_acr_pull,
    azurerm_role_assignment.app_kv_secret_user,
    azurerm_role_assignment.app_table_data,
  ]
}

# ---------- Alerting ----------

resource "azurerm_monitor_action_group" "email" {
  name                = "ag-shiplog-email"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "shiplog"
  tags                = local.tags

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "http_5xx" {
  name                = "alert-shiplog-5xx"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "ShipLog returned more than 5 server errors in 5 minutes"
  severity            = 2
  frequency           = "PT1M" # evaluate every minute...
  window_size         = "PT5M" # ...over the last 5 minutes
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
