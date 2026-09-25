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
  features {
    resource_group {
      # El RG del clúster contiene solo lo que crea este Terraform (el de
      # nodos es aparte y lo administra AKS). Si alguien agregó algo a mano,
      # destroy falla en vez de borrarlo en silencio.
      prevent_deletion_if_contains_resources = true
    }
  }
}
