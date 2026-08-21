# Storage Check - Diagnóstico READ-ONLY para Linux

Ferramenta de **diagnóstico de storage** para Linux que executa **apenas operações de leitura**, ideal para ambientes de produção. Fornece métricas de performance, saúde dos discos e recomendações baseadas em referências de mercado.

---

## 📋 Índice

- [Funcionalidades](#-funcionalidades)
- [Segurança](#-segurança-garantida)
- [Comando de Execução](#-comando-de-execução)
- [Dependências](#-dependências)
- [Interpretação dos Resultados](#-interpretação-dos-resultados)
- [Guia de Problemas e Soluções](#-guia-de-problemas-e-soluções)
  - [Latência Alta](#1-latência-alta)
  - [Espaço em Disco Crítico](#2-espaço-em-disco-crítico)
  - [SMART Indisponível em NVMe](#3-smart-indisponível-em-nvme)
  - [Velocidade de Leitura Baixa](#4-velocidade-de-leitura-baixa)
  - [IOPS Baixo](#5-iops-baixo)
  - [Utilização Alta do Disco](#6-utilização-alta-do-disco)
- [Referências de Performance](#-referências-de-performance)
- [Exemplo de Saída](#-exemplo-de-saída)

---

## 🎯 Funcionalidades

| Categoria | O que faz | Comandos utilizados |
|-----------|-----------|---------------------|
| **Descoberta** | Lista discos, partições, pontos de montagem e tipo de hardware | `lsblk`, `fdisk`, `findmnt` |
| **Performance** | Mede latência, velocidade de leitura e IOPS | `ioping`, `dd`, `hdparm` |
| **Saúde** | Verifica status SMART, temperatura e desgaste (wear level) | `smartctl` / `nvme-cli` |
| **Processos** | Mostra quais processos estão usando I/O e arquivos abertos | `iotop`, `lsof` |
| **Estatísticas** | Exibe utilização, filas de I/O e uso de inodes | `iostat`, `df` |
| **Benchmark** | Compara resultados com referências e classifica como ✅ Excelente, ⚠️ Aceitável ou ❌ Ruim | Interno |

---

## 🔒 Segurança Garantida

- **Nenhuma escrita** em disco ou sistema de arquivos
- Todos os comandos usam flags de **apenas leitura**:
  - `fsck -n` (no-execute)
  - `dd iflag=direct` (leitura pura, sem cache)
  - `smartctl -H` (apenas consulta)
  - `nvme smart-log` (apenas leitura de logs)
- **Seguro para produção** – pode ser executado em qualquer ambiente sem risco

---

## 🚀 Comando de Execução

Copie e cole o comando abaixo no terminal do servidor que deseja diagnosticar:

```bash
bash <(curl -sL https://raw.githubusercontent.com/tiagojulianoferreira/storage-check/main/storage-check.sh)
```

**Não requer**:
- Download de arquivos
- Criação de scripts locais
- Conhecimento avançado de shell script

---

## 📦 Dependências

O script verifica e instala automaticamente (com sua confirmação) os seguintes pacotes:

| Pacote | Função | Comando de instalação |
|--------|--------|----------------------|
| `ioping` | Medição de latência | `apt/yum install ioping` |
| `smartmontools` | Saúde SMART de discos SATA | `apt/yum install smartmontools` |
| `nvme-cli` | Saúde SMART de discos NVMe | `apt/yum install nvme-cli` |
| `sysstat` | Estatísticas de I/O (`iostat`) | `apt/yum install sysstat` |
| `hdparm` | Parâmetros e velocidade de discos | `apt/yum install hdparm` |
| `lsof` | Listagem de arquivos abertos | `apt/yum install lsof` |
| `iotop` | I/O por processo | `apt/yum install iotop` |
| `bc` | Cálculos de comparação | `apt/yum install bc` |

---

## 📊 Interpretação dos Resultados

### Quadro Comparativo

O script exibe um quadro comparativo com:

| Ícone | Significado | Ação Recomendada |
|-------|-------------|------------------|
| ✅ | OK - Dentro do esperado | Nenhuma ação necessária |
| 🟡 | ATENÇÃO - Requer monitoramento | Investigar e monitorar |
| 🔴 | RUIM - Requer ação imediata | Corrigir imediatamente |
| ℹ️ | INFO - Informação adicional | Apenas para conhecimento |

---

## 🔧 Guia de Problemas e Soluções

### 1. Latência Alta

**Sintoma:**
```
[5] TESTE DE LATÊNCIA (ioping)
  ⏱️  Latência média: 46.8ms
  ❌ LATÊNCIA MUITO ALTA (> 0ms)
```

**O que significa:**
A latência é o tempo que o disco leva para responder a uma requisição. Para um SSD NVMe, o esperado é **< 0.1ms**. Valores acima de **1ms** indicam problemas.

**Possíveis Causas:**

| Causa | Como identificar | Solução |
|-------|------------------|---------|
| **Uso intenso de swap** | `free -h` mostra swap > 50% | Aumentar RAM ou reduzir swappiness |
| **Processo com I/O pesado** | `sudo iotop -o` mostra processos com alta atividade | Identificar e ajustar o processo |
| **Sistema de arquivos cheio** | `df -h` mostra partição > 90% | Liberar espaço (ver seção 2) |
| **Driver NVMe desatualizado** | `dmesg \| grep nvme` mostra erros | Atualizar kernel/driver |
| **Temperatura alta** | `sudo nvme smart-log /dev/nvme0n1` mostra > 65°C | Melhorar resfriamento |
| **Agendador inadequado** | `cat /sys/block/nvme0n1/queue/scheduler` | Usar `none` ou `mq-deadline` |
| **Fragmentação (apenas HDD)** | `sudo e4defrag -c /` | Desfragmentar (apenas HDD) |

**Diagnóstico Passo a Passo:**

```bash
# 1. Verificar uso de memória e swap
free -h
echo "Swappiness atual: $(cat /proc/sys/vm/swappiness)"

# 2. Verificar processos com I/O
sudo iotop -o -n 5

# 3. Verificar temperatura do NVMe
sudo nvme smart-log /dev/nvme0n1 | grep temperature

# 4. Verificar agendador
cat /sys/block/nvme0n1/queue/scheduler

# 5. Verificar logs de erro
dmesg | grep -i "nvme\|i/o error" | tail -20
```

**Ações Corretivas:**

```bash
# Reduzir uso de swap (valor 10 = usar swap apenas quando necessário)
sudo sysctl vm.swappiness=10
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf

# Limpar cache de memória (seguro)
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches

# Trocar agendador para NVMe
echo "none" | sudo tee /sys/block/nvme0n1/queue/scheduler

# Verificar se há atualizações de firmware
sudo nvme list
sudo nvme fw-log /dev/nvme0n1  # Verifica versão do firmware
```

---

### 2. Espaço em Disco Crítico

**Sintoma:**
```
[3] USO DE ESPAÇO EM DISCO (df -hT)
/dev/nvme0n1p4 ext4      530G  462G   41G  92% /
❌ PROBLEMAS CRÍTICOS ENCONTRADOS:
  • Uso de disco em 92% em / (CRÍTICO)
```

**O que significa:**
Partição com menos de 10% de espaço livre. Pode causar:
- Falha em atualizações do sistema
- Logs não gravados
- Instabilidade do sistema
- Falha em criar arquivos temporários

**Diagnóstico Passo a Passo:**

```bash
# 1. Identificar pastas que mais ocupam espaço
sudo du -sh /* 2>/dev/null | sort -hr | head -10

# 2. Verificar logs
sudo du -sh /var/log/*
sudo journalctl --disk-usage

# 3. Verificar pacotes não utilizados
sudo apt list --installed | grep -v "installed" | head -20  # Debian/Ubuntu
sudo yum list installed | head -20  # RHEL/CentOS

# 4. Verificar diretórios pessoais grandes
du -sh /home/* 2>/dev/null | sort -hr | head -5
```

**Ações Corretivas (Prioridade):**

```bash
# ALTA PRIORIDADE - Liberar logs antigos
sudo journalctl --vacuum-size=500M
sudo journalctl --vacuum-time=7d

# ALTA PRIORIDADE - Limpar pacotes
sudo apt autoremove --purge          # Ubuntu/Debian
sudo apt clean                       # Ubuntu/Debian
sudo yum autoremove                  # RHEL/CentOS
sudo dnf autoremove                  # Fedora

# MÉDIA PRIORIDADE - Limpar cache de pacotes
sudo rm -rf /var/cache/apt/archives/*  # Ubuntu/Debian
sudo rm -rf /var/cache/yum/*           # RHEL/CentOS

# MÉDIA PRIORIDADE - Limpar diretórios temporários
sudo rm -rf /tmp/* 2>/dev/null
sudo rm -rf /var/tmp/* 2>/dev/null

# BAIXA PRIORIDADE - Remover kernels antigos (Ubuntu/Debian)
sudo apt autoremove --purge linux-image-*

# Identificar arquivos grandes (> 1GB) em todo o sistema
sudo find / -type f -size +1G -exec ls -lh {} \; 2>/dev/null | head -20
```

---

### 3. SMART Indisponível em NVMe

**Sintoma:**
```
[7] SAÚDE DO DISCO (SMART)
  ⚠️  nvme-cli não instalado - necessário para SMART em NVMe
  ou
  ⚠️  Não foi possível ler dados SMART do NVMe
```

**O que significa:**
Discos NVMe não usam o protocolo SMART tradicional (via `smartctl`). Eles exigem a ferramenta `nvme-cli` para leitura de logs de saúde.

**Solução:**

```bash
# Instalar nvme-cli
sudo apt install nvme-cli          # Ubuntu/Debian
sudo yum install nvme-cli          # RHEL/CentOS
sudo dnf install nvme-cli          # Fedora

# Testar leitura do SMART
sudo nvme smart-log /dev/nvme0n1

# Verificar informações detalhadas
sudo nvme id-ctrl /dev/nvme0n1
sudo nvme error-log /dev/nvme0n1
```

**O que os valores significam:**

| Métrica | Valor Saudável | Ação se crítico |
|---------|----------------|-----------------|
| **percentage_used** | < 60% | > 80% = substituir disco |
| **temperature** | < 50°C | > 65°C = melhorar resfriamento |
| **critical_warning** | 0 | Qualquer valor > 0 = verificar logs |
| **media_errors** | 0 | > 0 = possíveis problemas físicos |

---

### 4. Velocidade de Leitura Baixa

**Sintoma:**
```
[6] TESTE DE VELOCIDADE DE LEITURA (dd)
  📊 Velocidade: 150MB/s
  ⚠️  ACEITÁVEL (esperado 3000MB/s)
```

**O que significa:**
A velocidade de leitura sequencial está muito abaixo do esperado para o tipo de disco.

**Causas Comuns e Soluções:**

| Causa | Verificação | Solução |
|-------|-------------|---------|
| **PCIe em modo errado** | `lspci -vv \| grep -A5 "Non-Volatile"` | Verificar BIOS/UEFI, forçar PCIe Gen3/Gen4 |
| **Driver NVMe desatualizado** | `uname -r` | Atualizar kernel |
| **Temperatura alta** | `sudo nvme smart-log /dev/nvme0n1` | Melhorar resfriamento |
| **Firmware desatualizado** | `sudo nvme fw-log /dev/nvme0n1` | Atualizar firmware (consultar fabricante) |
| **Agendador inadequado** | `cat /sys/block/nvme0n1/queue/scheduler` | Usar `none` ou `mq-deadline` |
| **Cache cheio** | `sudo hdparm -W /dev/nvme0n1` | Verificar se write-cache está ativo |

**Diagnóstico Detalhado:**

```bash
# 1. Verificar link speed do NVMe
sudo nvme list
sudo nvme id-ctrl /dev/nvme0n1 | grep -i "pcie"

# 2. Verificar modo de energia
sudo nvme get-feature /dev/nvme0n1 -f 2 -H  # Power Management

# 3. Verificar agendador
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/read_ahead_kb

# 4. Teste com diferentes tamanhos de bloco
for bs in 4k 16k 64k 1M; do
    echo "Testando $bs..."
    sudo dd if=/dev/nvme0n1 of=/dev/null bs=$bs count=100000 iflag=direct 2>&1 | grep MB/s
done
```

---

### 5. IOPS Baixo

**Sintoma:**
```
[8] ESTATÍSTICAS DE I/O (iostat)
  ℹ️  IOPS: Baixo - Sistema ocioso?
```

**O que significa:**
IOPS (Input/Output Operations Per Second) baixo pode ser **normal** em sistemas ociosos, mas também pode indicar problemas.

**Quando é problema:**
- IOPS baixo **com alta utilização** (> 80%)
- IOPS baixo **com alta latência** (> 10ms)
- IOPS baixo **em pico de uso** (verifique horários de pico)

**Diagnóstico:**

```bash
# 1. Verificar se há processos com I/O
sudo iotop -o -n 5

# 2. Verificar fila de I/O
cat /sys/block/nvme0n1/queue/nr_requests
cat /proc/sys/vm/dirty_ratio
cat /proc/sys/vm/dirty_background_ratio

# 3. Verificar se há throttling
sudo dmesg | grep -i "throttle\|blocked" | tail -10
```

**Ações Corretivas (se necessário):**

```bash
# Ajustar parâmetros de I/O (valores para SSD/NVMe)
echo "512" | sudo tee /sys/block/nvme0n1/queue/nr_requests
echo "10" | sudo tee /proc/sys/vm/dirty_ratio
echo "5" | sudo tee /proc/sys/vm/dirty_background_ratio
```

---

### 6. Utilização Alta do Disco

**Sintoma:**
```
[8] ESTATÍSTICAS DE I/O (iostat)
  ❌ UTILIZAÇÃO MUITO ALTA (>80%)
```

**O que significa:**
O disco está sendo usado em mais de 80% da sua capacidade de I/O. Isso pode indicar gargalo.

**Diagnóstico:**

```bash
# 1. Identificar processos com alto I/O
sudo iotop -o -n 10

# 2. Verificar estatísticas detalhadas
sudo iostat -x 1 10

# 3. Verificar se há muitas operações pequenas
# (r_await e w_await altos indicam problema)
```

**Ações Corretivas:**

```bash
# 1. Ajustar agendador para SSD/NVMe
echo "none" | sudo tee /sys/block/nvme0n1/queue/scheduler

# 2. Ajustar leitura antecipada (read-ahead)
echo "256" | sudo tee /sys/block/nvme0n1/queue/read_ahead_kb

# 3. Verificar se há processos com muitas operações pequenas
# Considere usar banco de dados com cache adequado
```

---

## 📊 Referências de Performance

| Tipo de Disco | Velocidade Leitura | IOPS | Latência |
|---------------|-------------------|------|----------|
| HDD 7.2K RPM | 80-120 MB/s | 150 | 8-12 ms |
| HDD 10K RPM | 120-180 MB/s | 200 | 5-8 ms |
| HDD 15K RPM | 180-250 MB/s | 300 | 3-5 ms |
| SATA SSD | 500-550 MB/s | 50K | 0.1-1 ms |
| NVMe Gen3 | 2.000-3.500 MB/s | 250K | 0.02-0.1 ms |
| NVMe Gen4 | 4.000-7.000 MB/s | 500K | 0.01-0.05 ms |

**Multiplicadores RAID (leitura):**
- RAID 0: x2 (speed)
- RAID 1: x1 (redundância)
- RAID 5: x3 (read speed)
- RAID 6: x4 (read speed)
- RAID 10: x4 (read speed)

---

## 📋 Exemplo de Saída

```
═══════════════════════════════════════════════════════════════
              QUADRO COMPARATIVO - IDEAL vs DIAGNOSTICADO
═══════════════════════════════════════════════════════════════

  +---------------------+----------------------+----------------------+
  | COMPONENTE          | ESPERADO             | DIAGNOSTICADO        |
  +---------------------+----------------------+----------------------+
  | Disco               | NVMe SSD             | NVMe SSD             |
  | Espaço em /         | < 90%                | 🔴 92%               |
  | Latência            | < 0.1ms              | 🔴 46.8ms            |
  | Velocidade          | ≥ 3000MB/s           | ℹ️ N/A               |
  | Temperatura         | < 50°C               | ✅ 27°C              |
  | Desgaste            | < 60%                | ✅ 3%                |
  | Utilização          | < 50%                | ✅ 0.80%             |
  | IOPS                | ≥ 500000             | ℹ️ 0.00              |
  | Swap                | < 50%                | ✅ 3%                |
  | Agendador           | none/noop/deadline   | ✅ none              |
  +---------------------+----------------------+----------------------+

  📌 LEGENDA:
    ✅  - OK (dentro do esperado)
    🟡  - ATENÇÃO (requer monitoramento)
    🔴  - RUIM (requer ação imediata)
    ℹ️  - INFO (informação adicional)

  ❌ PROBLEMAS CRÍTICOS ENCONTRADOS:
    • Uso de disco em 92% em / (CRÍTICO)

  ⚠️  AVISOS:
    • Latência 46.8ms acima do esperado (0.1ms)
    • Velocidade abaixo do esperado (3000MB/s)

  ℹ️  INFORMAÇÕES ADICIONAIS:
    • Teste de velocidade não concluído
    • IOPS baixo (0.00) - provavelmente sistema ocioso

═══════════════════════════════════════════════════════════════
✅ TODOS OS TESTES EXECUTADOS EM MODO SOMENTE LEITURA
✅ NENHUMA ALTERAÇÃO FOI FEITA NO SISTEMA
✅ SEGURO PARA AMBIENTES DE PRODUÇÃO
═══════════════════════════════════════════════════════════════
```

---

## 🤝 Contribuição

Sinta-se à vontade para abrir issues ou pull requests no repositório oficial:  
[https://github.com/tiagojulianoferreira/storage-check](https://github.com/tiagojulianoferreira/storage-check)

---

## 📝 Licença

GPL– Use e modifique livremente.

