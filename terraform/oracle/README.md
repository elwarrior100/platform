# Terraform: VM Oracle (Always Free, Ampere A1)

Cria a VM onde a plataforma vai correr (k3s + o resto), com a mesma forma e subnet pública que já usámos.
⚠️ **Antes do primeiro `apply`:** criar um orçamento/alerta de custos na consola OCI (Billing → Budgets) e confirmar o teto
Always Free na tua conta (ver docs/PLAN.md §12.1).

Pré-requisitos: `~/.oci/config` com o perfil `DEFAULT` e uma chave SSH em `~/.ssh/id_ed25519.pub`.

```bash
cd platform/terraform/oracle
cp terraform.tfvars.example terraform.tfvars   # preencher os OCIDs
terraform init
terraform plan
terraform apply
```

**Sem capacidade** ("Out of host capacity"): o Terraform falha logo e não repete. Para insistir:

```bash
until terraform apply -auto-approve; do echo "Sem capacidade. Nova tentativa em 5 minutos."; sleep 300; done
```

Se a VM já existir, o `apply` não tem nada a fazer e o ciclo termina, por isso não cria duplicados.

**Cuidados**
- O `terraform.tfstate` contém dados sensíveis e fica fora do git (ver `.gitignore`).
- O Always Free dá 4 OCPU / 24 GB / 200 GB de disco **no total** às instâncias A1 da conta. Os valores por omissão
  (2 / 12 / 100) usam tudo o que cabe; se já tens outra VM A1, baixa `ocpus`, `memory_in_gbs` e `boot_volume_size_in_gbs`.
- `ignore_changes` na imagem impede que uma versão nova do Ubuntu recrie a VM.
- Confirmar a versão do provider em registry.terraform.io antes de a fixar (aqui está `>= 5.0`).
