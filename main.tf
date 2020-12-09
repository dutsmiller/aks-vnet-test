terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.32.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=2.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "=1.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "=1.3.2"
    }
  }
  required_version = "=0.13.5"
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  alias                  = "no_vnet"
  host                   = azurerm_kubernetes_cluster.no_vnet.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.no_vnet.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.no_vnet.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.no_vnet.kube_config.0.cluster_ca_certificate)
  load_config_file       = false
}

provider "kubernetes" {
  alias                  = "vnet"
  host                   = azurerm_kubernetes_cluster.vnet.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.vnet.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.vnet.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.vnet.kube_config.0.cluster_ca_certificate)
  load_config_file       = false
}

provider "helm" {
  alias = "no_vnet"
  kubernetes {
    host                   = azurerm_kubernetes_cluster.no_vnet.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.no_vnet.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.no_vnet.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.no_vnet.kube_config.0.cluster_ca_certificate)
  }
}

provider "helm" {
  alias = "vnet"
  kubernetes {
    host                   = azurerm_kubernetes_cluster.vnet.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.vnet.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.vnet.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.vnet.kube_config.0.cluster_ca_certificate)
  }
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

resource "random_string" "random" {
  length  = 12
  upper   = false
  special = false
}

resource "azurerm_resource_group" "no_vnet" {
  name     = "akstest-random_string.random.result"
  location = "East US 2"
}

resource "azurerm_resource_group" "vnet" {
  name     = "akstest-vnet-${random_string.random.result}"
  location = "East US 2"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "akstest-vnet-${random_string.random.result}"
  location            = azurerm_resource_group.vnet.location
  resource_group_name = azurerm_resource_group.vnet.name
  address_space       = ["10.1.0.0/22"]
}

resource "azurerm_subnet" "subnet" {
  name                 = "akstest-vnet-${random_string.random.result}"
  resource_group_name  = azurerm_resource_group.vnet.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.0.0/24"]
}

resource "azurerm_network_security_group" "nsg" {
  name                = "akstest-vnet-${random_string.random.result}"
  location            = azurerm_resource_group.vnet.location
  resource_group_name = azurerm_resource_group.vnet.name

}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_kubernetes_cluster" "no_vnet" {
  name                = "akstest-${random_string.random.result}"
  location            = azurerm_resource_group.no_vnet.location
  resource_group_name = azurerm_resource_group.no_vnet.name
  dns_prefix          = "akstest-${random_string.random.result}" 

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_B2s"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_kubernetes_cluster" "vnet" {
  name                = "akstest-vnet-${random_string.random.result}"
  location            = azurerm_resource_group.vnet.location
  resource_group_name = azurerm_resource_group.vnet.name
  dns_prefix          = "akstest-vnet-${random_string.random.result}" 

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = "Standard_B2s"
    vnet_subnet_id = azurerm_subnet.subnet.id
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "subnet_network_contributor" {
  scope                = azurerm_subnet.subnet.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.vnet.kubelet_identity.0.object_id
}

resource "helm_release" "no_vnet_apache" {
  provider   = helm.no_vnet
  name       = "apache"
  repository = "bitnami"
  chart      = "apache"
}

resource "helm_release" "vnet_apache" {
  depends_on = [azurerm_role_assignment.subnet_network_contributor]
  provider   = helm.vnet
  name       = "apache"
  repository = "bitnami"
  chart      = "apache"
}

data "kubernetes_service" "no_vnet_apache" {
  depends_on = [helm_release.no_vnet_apache] 
  provider   = kubernetes.no_vnet
  metadata {
    name = "apache"
  }
}

data "kubernetes_service" "vnet_apache" {
  depends_on = [helm_release.vnet_apache] 
  provider   = kubernetes.vnet
  metadata {
    name = "apache"
  }
}

output "no_vnet_apache_ip" {
  value = data.kubernetes_service.no_vnet_apache.load_balancer_ingress.0.ip
}

output "vnet_apache_ip" {
  value = data.kubernetes_service.vnet_apache.load_balancer_ingress.0.ip
}

output "no_vnet_aks_login" {
  value = "az aks get-credentials --name ${azurerm_kubernetes_cluster.no_vnet.name} --resource-group ${azurerm_resource_group.no_vnet.name}"
}

output "vnet_aks_login" {
  value = "az aks get-credentials --name ${azurerm_kubernetes_cluster.vnet.name} --resource-group ${azurerm_resource_group.vnet.name}"
}
