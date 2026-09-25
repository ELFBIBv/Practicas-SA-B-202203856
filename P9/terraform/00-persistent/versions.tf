terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }
}

# La suscripción llega por ARM_SUBSCRIPTION_ID (la exporta bootstrap.sh) y la
# autenticación es la sesión de `az login`: nada de credenciales en el código.
provider "azurerm" {
  features {}
}
