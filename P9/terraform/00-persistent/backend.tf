# Backend remoto con bloqueo (blob lease de Azure Storage). Misma cuenta y
# contenedor que 01-cluster/02-platform, con su propia key
# (p9/00-persistent.tfstate): no hay problema de huevo-y-gallina aquí, porque
# el backend YA existe cuando esta etapa corre (bootstrap.sh lo asegura con
# Azure CLI en la etapa 1, antes de cualquier `terraform init`). A diferencia
# del backend mismo, esta etapa SÍ puede vivir en Terraform: no bootstrapea su
# propio almacenamiento de estado, solo usa uno que ya existe.
#
# Configuración parcial a propósito: ningún valor queda fijo en el código y
# ninguna credencial pasa por aquí. P9/scripts/bootstrap.sh ejecuta
# `terraform init -backend-config=...` con subscription_id, resource_group_name,
# storage_account_name, container_name, key y use_azuread_auth.
# Ver P9/docs/terraform-backend.md y P9/docs/diseno-velero.md §2.
#
# Nunca pase access_key por -backend-config: Terraform guardaría el valor en
# texto plano en .terraform/terraform.tfstate.
terraform {
  backend "azurerm" {}
}
