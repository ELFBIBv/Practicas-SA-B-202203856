# Backend remoto con bloqueo (blob lease de Azure Storage).
#
# Configuración parcial a propósito: ningún valor queda fijo en el código y
# ninguna credencial pasa por aquí. P9/scripts/bootstrap.sh asegura que la
# cuenta y el contenedor existan y luego ejecuta `terraform init
# -backend-config=...` (key p9/02-platform.tfstate) con subscription_id, resource_group_name,
# storage_account_name, container_name, key y use_azuread_auth.
# Ver P9/docs/terraform-backend.md.
#
# Nunca pase access_key por -backend-config: Terraform guardaría el valor en
# texto plano en .terraform/terraform.tfstate.
terraform {
  backend "azurerm" {}
}
