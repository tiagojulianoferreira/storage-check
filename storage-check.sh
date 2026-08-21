#!/bin/bash
# Storage Check - Diagnóstico READ-ONLY para Linux
# Autor: Tiago Ferreira
# Repositório: https://github.com/tiagojulianoferreira/storage-check
# Versão: 2.2 - Com quadro comparativo final e lógica aprimorada

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Variáveis para acumular resultados
PROBLEMS=()
WARNINGS=()
INFO=()
CHECK_RESULTS=()

# Função para perguntar ao usuário
ask_confirm() {
    local prompt="$1"
    local response
    read -p "$prompt (y/N): " response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Função para detectar gerenciador de pacotes
detect_package_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# Função para instalar pacote
install_package() {
    local package=$1
    local pm=$(detect_package_manager)
    local cmd=""
    
    echo -e "${YELLOW}📦 Instalando $package...${NC}"
    
    case $pm in
        apt)
            cmd="sudo apt install -y $package"
            ;;
        yum)
            cmd="sudo yum install -y $package"
            ;;
        dnf)
            cmd="sudo dnf install -y $package"
            ;;
        zypper)
            cmd="sudo zypper install -y $package"
            ;;
        pacman)
            cmd="sudo pacman -S --noconfirm $package"
            ;;
        *)
            echo -e "${RED}❌ Gerenciador de pacotes não encontrado. Instale $package manualmente.${NC}"
            return 1
            ;;
    esac
    
    if eval $cmd 2>/dev/null; then
        echo -e "${GREEN}✅ $package instalado com sucesso.${NC}"
        return 0
    else
        echo -e "${RED}❌ Falha ao instalar $package. Instale manualmente.${NC}"
        return 1
    fi
}

# ============================================================
# VERIFICAÇÃO DE DEPENDÊNCIAS
# ============================================================

echo -e "${BLUE}=== STORAGE CHECK - VERIFICAÇÃO DE DEPENDÊNCIAS ===${NC}"
echo ""

# Lista de dependências base
dependencies=(
    "ioping:ioping"
    "smartctl:smartmontools"
    "iostat:sysstat"
    "hdparm:hdparm"
    "lsof:lsof"
    "lsblk:util-linux"
    "fdisk:util-linux"
    "findmnt:util-linux"
    "iotop:iotop"
    "bc:bc"
)

# VERIFICA SE EXISTE DISCO NVMe
HAS_NVME=false
for d in nvme0n1 nvme1n1; do
    if [ -e /dev/$d ]; then
        HAS_NVME=true
        break
    fi
done

# Se tiver NVMe, adiciona nvme-cli como dependência
if [ "$HAS_NVME" = true ]; then
    dependencies+=("nvme:nvme-cli")
fi

# Verifica quais dependências faltam
MISSING=()
for dep in "${dependencies[@]}"; do
    cmd="${dep%:*}"
    pkg="${dep#*:}"
    if ! command -v $cmd &>/dev/null; then
        MISSING+=("$pkg")
    fi
done

# Exibe dependências faltantes de forma clara
if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Dependências faltando:${NC}"
    for pkg in "${MISSING[@]}"; do
        echo -e "  ${YELLOW}• $pkg${NC}"
    done
    echo ""
    if ask_confirm "Instalar todas as dependências faltantes?"; then
        for pkg in "${MISSING[@]}"; do
            install_package $pkg
        done
        echo -e "${GREEN}✅ Instalação concluída.${NC}"
    else
        echo -e "${BLUE}ℹ️  Pulando instalação. Algumas verificações serão ignoradas.${NC}"
        WARNINGS+=("Dependências não instaladas: ${MISSING[*]}")
    fi
else
    echo -e "${GREEN}✅ Todas as dependências estão instaladas.${NC}"
fi

echo ""
echo -e "${GREEN}✅ Verificação de dependências concluída. Iniciando análise de storage...${NC}"
echo ""

# ============================================================
# INÍCIO DA ANÁLISE DE STORAGE (READ-ONLY)
# ============================================================

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}      DIAGNÓSTICO DE STORAGE - MODO SOMENTE LEITURA${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# 1. DETECTAR TIPO DE DISCO E RAID
echo -e "${BOLD}[1] DISPOSITIVO DETECTADO${NC}"
EXPECTED_IOPS=0
EXPECTED_LATENCY=0
EXPECTED_READ_MB=0
DISK_FOUND=""
IS_NVME=false
DISK_TYPE=""

for d in sda sdb sdc nvme0n1 nvme1n1 vda vdb; do
  if [ -e /dev/$d ]; then
    TYPE=$(cat /sys/block/$d/queue/rotational 2>/dev/null)
    
    # Detecta se é NVMe pelo nome
    if [[ "$d" == nvme* ]]; then
        IS_NVME=true
        DISK_TYPE="NVMe SSD"
        EXPECTED_IOPS=500000
        EXPECTED_LATENCY=0.1
        EXPECTED_READ_MB=3000
    elif [ "$TYPE" = "0" ]; then
        DISK_TYPE="SSD (SATA)"
        EXPECTED_IOPS=50000
        EXPECTED_LATENCY=0.5
        EXPECTED_READ_MB=500
    elif [ "$TYPE" = "1" ]; then
        DISK_TYPE="HDD"
        EXPECTED_IOPS=150
        EXPECTED_LATENCY=8
        EXPECTED_READ_MB=150
    else
        DISK_TYPE="Desconhecido"
        EXPECTED_IOPS=1000
        EXPECTED_LATENCY=5
        EXPECTED_READ_MB=200
    fi
    
    # Detectar RAID via mdstat
    if [ -e /proc/mdstat ]; then
        RAID_INFO=$(grep -A1 "^$d" /proc/mdstat 2>/dev/null | grep -E "raid[0-9]" | awk "{print \$1}")
        if [ -n "$RAID_INFO" ]; then
            RAID_TYPE=$(echo $RAID_INFO | cut -d"_" -f1)
            case $RAID_TYPE in
                raid0) RAID_MULTIPLIER=2; EXPECTED_READ_MB=$((EXPECTED_READ_MB * 2));;
                raid1) RAID_MULTIPLIER=1; EXPECTED_READ_MB=$((EXPECTED_READ_MB * 1));;
                raid5) RAID_MULTIPLIER=3; EXPECTED_READ_MB=$((EXPECTED_READ_MB * 3));;
                raid6) RAID_MULTIPLIER=4; EXPECTED_READ_MB=$((EXPECTED_READ_MB * 4));;
                raid10) RAID_MULTIPLIER=4; EXPECTED_READ_MB=$((EXPECTED_READ_MB * 4));;
                *) RAID_MULTIPLIER=1;;
            esac
        else
            RAID_TYPE="Nenhum"
            RAID_MULTIPLIER=1
        fi
    else
        RAID_TYPE="Nenhum"
        RAID_MULTIPLIER=1
    fi
    
    MODEL=$(lsblk -o NAME,MODEL /dev/$d 2>/dev/null | grep "^$d" | awk '{$1=""; print $0}' | xargs)
    SIZE=$(lsblk -o NAME,SIZE /dev/$d 2>/dev/null | grep "^$d" | awk '{print $2}')
    
    echo "  📌 /dev/$d: $DISK_TYPE | $SIZE | $MODEL"
    echo "     RAID: $RAID_TYPE | Esperado: ${EXPECTED_READ_MB}MB/s | IOPS: $EXPECTED_IOPS | Latência: ${EXPECTED_LATENCY}ms"
    DISK_FOUND="/dev/$d"
    break
  fi
done

if [ -z "$DISK_FOUND" ]; then
    echo "  ⚠️ Nenhum disco encontrado!"
    PROBLEMS+=("Nenhum disco detectado")
fi

# 2. PARTIÇÕES E PONTOS DE MONTAGEM
echo -e "\n${BOLD}[2] PARTIÇÕES E PONTOS DE MONTAGEM (lsblk)${NC}"
if command -v lsblk &>/dev/null; then
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL 2>/dev/null | grep -v "loop" | head -20
else
    echo "  ⚠️ lsblk não disponível"
    WARNINGS+=("lsblk não instalado")
fi

# 3. USO DE ESPAÇO EM DISCO (FILTRA PARTIÇÕES REAIS)
echo -e "\n${BOLD}[3] USO DE ESPAÇO EM DISCO (df -hT)${NC}"
# Filtra apenas sistemas de arquivos reais (ignora efivarfs, tmpfs, etc)
REAL_FS=$(df -hT 2>/dev/null | grep -E "^/dev" | head -15)
if [ -n "$REAL_FS" ]; then
    echo "$REAL_FS"
else
    echo "  Nenhum sistema de arquivos real encontrado"
fi

# Verifica uso de espaço > 90% apenas em partições reais
DF_OUTPUT=$(df -hT 2>/dev/null | grep -E "^/dev" | awk 'NR>0 {print $7, $6}' | sed 's/%//')
while read -r mount usage; do
    if [ -n "$usage" ] && [ "$usage" -gt 90 ] 2>/dev/null; then
        PROBLEMS+=("Uso de disco em ${usage}% em $mount (CRÍTICO)")
        CHECK_RESULTS+=("🔴 ESPAÇO: $mount está ${usage}% cheio (CRÍTICO)")
    elif [ -n "$usage" ] && [ "$usage" -gt 80 ] 2>/dev/null; then
        WARNINGS+=("Uso de disco em ${usage}% em $mount")
        CHECK_RESULTS+=("🟡 ESPAÇO: $mount está ${usage}% cheio (ATENÇÃO)")
    fi
done <<< "$DF_OUTPUT"

# 4. USO DE INODES (FILTRA PARTIÇÕES REAIS)
echo -e "\n${BOLD}[4] USO DE INODES (df -iT)${NC}"
REAL_INODES=$(df -iT 2>/dev/null | grep -E "^/dev" | head -15)
if [ -n "$REAL_INODES" ]; then
    echo "$REAL_INODES"
else
    echo "  Nenhum sistema de arquivos real encontrado"
fi

# 5. TESTE DE LATÊNCIA (ioping) - CORRIGIDO
echo -e "\n${BOLD}[5] TESTE DE LATÊNCIA (ioping)${NC}"
if command -v ioping &>/dev/null; then
    LATENCY_RAW=$(ioping -c 5 -q . 2>/dev/null | grep "avg" | awk "{print \$3}" | sed "s/ms//")
    if [ -n "$LATENCY_RAW" ]; then
        LATENCY_CLEAN=$(echo $LATENCY_RAW | sed 's/,/./')
        echo "  ⏱️  Latência média: ${LATENCY_CLEAN}ms"
        
        # Comparação segura usando bc
        if command -v bc &>/dev/null; then
            # Converte para números com ponto decimal
            LATENCY_NUM=$(echo "$LATENCY_CLEAN" | sed 's/,/./')
            EXPECTED_NUM=$(echo "$EXPECTED_LATENCY" | sed 's/,/./')
            
            if (( $(echo "$LATENCY_NUM < $EXPECTED_NUM" | bc -l 2>/dev/null || echo 0) )); then
                echo -e "  ${GREEN}✅ EXCELENTE (abaixo de ${EXPECTED_LATENCY}ms)${NC}"
                CHECK_RESULTS+=("✅ LATÊNCIA: ${LATENCY_CLEAN}ms (Excelente)")
            elif (( $(echo "$LATENCY_NUM < $EXPECTED_NUM * 2" | bc -l 2>/dev/null || echo 0) )); then
                echo -e "  ${YELLOW}⚠️  ACEITÁVEL (esperado ${EXPECTED_LATENCY}ms)${NC}"
                WARNINGS+=("Latência ${LATENCY_CLEAN}ms acima do esperado (${EXPECTED_LATENCY}ms)")
                CHECK_RESULTS+=("🟡 LATÊNCIA: ${LATENCY_CLEAN}ms (Aceitável)")
            else
                echo -e "  ${RED}❌ LATÊNCIA MUITO ALTA (> $((EXPECTED_LATENCY*2))ms)${NC}"
                PROBLEMS+=("Latência alta: ${LATENCY_CLEAN}ms (esperado ${EXPECTED_LATENCY}ms)")
                CHECK_RESULTS+=("🔴 LATÊNCIA: ${LATENCY_CLEAN}ms (Muito Alta)")
            fi
        else
            echo "  ⚠️ bc não instalado - comparação precisa não disponível"
            WARNINGS+=("bc não instalado para comparação de latência")
        fi
    else
        echo "  ioping: sem dados coletados"
        WARNINGS+=("ioping não retornou dados")
    fi
else
    echo "  ⚠️ ioping não instalado - teste de latência ignorado"
    WARNINGS+=("ioping não instalado")
fi

# 6. TESTE DE VELOCIDADE (dd) - AJUSTADO PARA USAR O DISCO CORRETO
echo -e "\n${BOLD}[6] TESTE DE VELOCIDADE DE LEITURA (dd)${NC}"
if [ -n "$DISK_FOUND" ]; then
    # Usa o disco encontrado (pode ser NVMe ou SATA)
    echo "  Testando $DISK_FOUND (pode levar alguns segundos)..."
    DD_RESULT=$(dd if=$DISK_FOUND of=/dev/null bs=1M count=500 iflag=direct 2>&1 | grep "MB/s" | awk "{print \$NF}")
    if [ -n "$DD_RESULT" ]; then
        echo "  📊 Velocidade: ${DD_RESULT}MB/s"
        DD_RATE=$(echo $DD_RESULT | cut -d"." -f1 2>/dev/null)
        if [ -n "$DD_RATE" ] && [ $DD_RATE -ge $EXPECTED_READ_MB ] 2>/dev/null; then
            echo -e "  ${GREEN}✅ EXCELENTE (≥ ${EXPECTED_READ_MB}MB/s)${NC}"
            CHECK_RESULTS+=("✅ VELOCIDADE: ${DD_RESULT}MB/s (Excelente)")
        elif [ -n "$DD_RATE" ] && [ $DD_RATE -ge $((EXPECTED_READ_MB * 60 / 100)) ] 2>/dev/null; then
            echo -e "  ${YELLOW}⚠️  ACEITÁVEL (esperado ${EXPECTED_READ_MB}MB/s)${NC}"
            WARNINGS+=("Velocidade ${DD_RESULT}MB/s abaixo do esperado (${EXPECTED_READ_MB}MB/s)")
            CHECK_RESULTS+=("🟡 VELOCIDADE: ${DD_RESULT}MB/s (Aceitável)")
        elif [ -n "$DD_RATE" ]; then
            echo -e "  ${RED}❌ VELOCIDADE BAIXA (< $((EXPECTED_READ_MB * 60 / 100))MB/s)${NC}"
            PROBLEMS+=("Velocidade de leitura baixa: ${DD_RESULT}MB/s")
            CHECK_RESULTS+=("🔴 VELOCIDADE: ${DD_RESULT}MB/s (Baixa)")
        fi
    else
        echo "  Não foi possível obter velocidade do disco"
        INFO+=("Teste de velocidade não concluído")
    fi
else
    echo "  Nenhum disco encontrado para teste de velocidade"
    INFO+=("Teste de velocidade ignorado (sem disco detectado)")
fi

# 7. SAUDE SMART (COM SUPORTE A NVMe)
echo -e "\n${BOLD}[7] SAÚDE DO DISCO (SMART)${NC}"
SMART_CHECKED=0

if [ "$IS_NVME" = true ] && command -v nvme &>/dev/null; then
    echo "  📌 Usando nvme-cli para leitura SMART do NVMe:"
    for d in nvme0n1 nvme1n1; do
        if [ -e /dev/$d ]; then
            echo "  /dev/$d:"
            SMART_LOG=$(sudo nvme smart-log /dev/$d 2>/dev/null)
            if [ -n "$SMART_LOG" ]; then
                TEMP=$(echo "$SMART_LOG" | grep "temperature" | awk '{print $3}' | sed 's/+//' | sed 's/C//')
                WEAR=$(echo "$SMART_LOG" | grep "percentage_used" | awk '{print $3}' | sed 's/%//')
                
                echo "    Temperatura: ${TEMP}°C"
                echo "    Desgaste: ${WEAR}%"
                
                if [ -n "$TEMP" ] && [ $TEMP -gt 65 ] 2>/dev/null; then
                    echo -e "    ${RED}❌ TEMPERATURA ALTA (>65°C)${NC}"
                    PROBLEMS+=("Temperatura alta (${TEMP}°C) em /dev/$d")
                    CHECK_RESULTS+=("🔴 TEMPERATURA: ${TEMP}°C (Alta)")
                elif [ -n "$TEMP" ] && [ $TEMP -gt 50 ] 2>/dev/null; then
                    echo -e "    ${YELLOW}⚠️  TEMPERATURA QUENTE (50-65°C)${NC}"
                    WARNINGS+=("Temperatura ${TEMP}°C em /dev/$d")
                    CHECK_RESULTS+=("🟡 TEMPERATURA: ${TEMP}°C (Quente)")
                elif [ -n "$TEMP" ]; then
                    echo -e "    ${GREEN}✅ TEMPERATURA ADEQUADA (<50°C)${NC}"
                    CHECK_RESULTS+=("✅ TEMPERATURA: ${TEMP}°C (Adequada)")
                fi
                
                if [ -n "$WEAR" ] && [ $WEAR -gt 80 ] 2>/dev/null; then
                    echo -e "    ${RED}❌ DESGASTE CRÍTICO (>80%)${NC}"
                    PROBLEMS+=("Desgaste ${WEAR}% em /dev/$d")
                    CHECK_RESULTS+=("🔴 DESGASTE: ${WEAR}% (Crítico)")
                elif [ -n "$WEAR" ] && [ $WEAR -gt 60 ] 2>/dev/null; then
                    echo -e "    ${YELLOW}⚠️  DESGASTE MODERADO (60-80%)${NC}"
                    WARNINGS+=("Desgaste ${WEAR}% em /dev/$d")
                    CHECK_RESULTS+=("🟡 DESGASTE: ${WEAR}% (Moderado)")
                elif [ -n "$WEAR" ]; then
                    echo -e "    ${GREEN}✅ DESGASTE SAUDÁVEL (<60%)${NC}"
                    CHECK_RESULTS+=("✅ DESGASTE: ${WEAR}% (Saudável)")
                fi
                
                echo -e "    ${GREEN}✅ SMART: DADOS LIDOS COM SUCESSO (via nvme-cli)${NC}"
                SMART_CHECKED=1
            else
                echo -e "    ${YELLOW}⚠️  Não foi possível ler dados SMART do NVMe${NC}"
                WARNINGS+=("Não foi possível ler SMART do NVMe /dev/$d")
            fi
            break
        fi
    done
elif [ "$IS_NVME" = true ] && ! command -v nvme &>/dev/null; then
    echo -e "  ${YELLOW}⚠️  nvme-cli não instalado - necessário para SMART em NVMe${NC}"
    WARNINGS+=("nvme-cli não instalado - SMART NVMe indisponível")
fi

# Fallback para SMART tradicional (se não for NVMe ou se NVMe falhou)
if [ $SMART_CHECKED -eq 0 ] && command -v smartctl &>/dev/null; then
    echo "  📌 Usando smartctl para leitura SMART:"
    for d in sda sdb sdc; do
        if [ -e /dev/$d ]; then
            SMART_RESULT=$(smartctl -H /dev/$d 2>/dev/null | grep -i "test result" | awk -F: "{print \$2}" | xargs)
            TEMP=$(smartctl -A /dev/$d 2>/dev/null | grep "Temperature_Celsius" | awk "{print \$10}")
            
            echo "  /dev/$d:"
            echo "    Status: $SMART_RESULT"
            [ -n "$TEMP" ] && echo "    Temperatura: ${TEMP}°C"
            
            if echo "$SMART_RESULT" | grep -qi "passed"; then
                echo -e "    ${GREEN}✅ SMART: APROVADO${NC}"
                CHECK_RESULTS+=("✅ SMART: Aprovado")
            else
                echo -e "    ${RED}❌ SMART: FALHA${NC}"
                PROBLEMS+=("SMART falhou em /dev/$d")
                CHECK_RESULTS+=("🔴 SMART: Falha")
            fi
            SMART_CHECKED=1
            break
        fi
    done
fi

if [ $SMART_CHECKED -eq 0 ]; then
    echo "  Nenhum dado SMART disponível para os discos detectados"
    INFO+=("SMART não disponível para os discos atuais")
fi

# 8. IOSTAT COM INTERPRETAÇÃO CORRETA
echo -e "\n${BOLD}[8] ESTATÍSTICAS DE I/O (iostat)${NC}"
if command -v iostat &>/dev/null; then
    IOSTAT_OUT=$(iostat -x 1 2 2>/dev/null | grep -E "^sd|^nvme" | tail -1)
    
    if [ -n "$IOSTAT_OUT" ]; then
        IOPS_READ=$(echo $IOSTAT_OUT | awk '{print $4}')
        IOPS_WRITE=$(echo $IOSTAT_OUT | awk '{print $8}')
        UTIL=$(echo $IOSTAT_OUT | awk '{print $NF}')
        AWAIT=$(echo $IOSTAT_OUT | awk '{print $10}')
        
        IOPS_READ_CLEAN=$(echo $IOPS_READ | sed 's/,/./')
        IOPS_WRITE_CLEAN=$(echo $IOPS_WRITE | sed 's/,/./')
        UTIL_CLEAN=$(echo $UTIL | sed 's/,/./')
        AWAIT_CLEAN=$(echo $AWAIT | sed 's/,/./')
        
        echo "  📊 Resumo da última amostra:"
        echo "     Leituras/s: ${IOPS_READ_CLEAN} | Escritas/s: ${IOPS_WRITE_CLEAN}"
        echo "     Utilização: ${UTIL_CLEAN}% | Tempo médio de espera: ${AWAIT_CLEAN}ms"
        
        if command -v bc &>/dev/null; then
            if (( $(echo "$UTIL_CLEAN > 80" | bc -l) )); then
                echo -e "  ${RED}❌ UTILIZAÇÃO MUITO ALTA (>80%)${NC}"
                PROBLEMS+=("Utilização alta: ${UTIL_CLEAN}%")
                CHECK_RESULTS+=("🔴 UTILIZAÇÃO: ${UTIL_CLEAN}% (Alta)")
            elif (( $(echo "$UTIL_CLEAN > 50" | bc -l) )); then
                echo -e "  ${YELLOW}⚠️  UTILIZAÇÃO MODERADA (50-80%)${NC}"
                WARNINGS+=("Utilização ${UTIL_CLEAN}%")
                CHECK_RESULTS+=("🟡 UTILIZAÇÃO: ${UTIL_CLEAN}% (Moderada)")
            else
                echo -e "  ${GREEN}✅ UTILIZAÇÃO BAIXA (<50%)${NC}"
                CHECK_RESULTS+=("✅ UTILIZAÇÃO: ${UTIL_CLEAN}% (Baixa)")
            fi
            
            if (( $(echo "$IOPS_READ_CLEAN >= $EXPECTED_IOPS" | bc -l) )); then
                echo -e "  ${GREEN}✅ IOPS: Excelente ($IOPS_READ_CLEAN ≥ $EXPECTED_IOPS)${NC}"
                CHECK_RESULTS+=("✅ IOPS: ${IOPS_READ_CLEAN} (Excelente)")
            elif (( $(echo "$IOPS_READ_CLEAN >= $EXPECTED_IOPS * 0.5" | bc -l) )); then
                echo -e "  ${YELLOW}⚠️  IOPS: Aceitável (esperado $EXPECTED_IOPS)${NC}"
                WARNINGS+=("IOPS ${IOPS_READ_CLEAN} abaixo do esperado (${EXPECTED_IOPS})")
                CHECK_RESULTS+=("🟡 IOPS: ${IOPS_READ_CLEAN} (Aceitável)")
            else
                echo -e "  ${YELLOW}ℹ️  IOPS: Baixo - Sistema ocioso?${NC}"
                INFO+=("IOPS baixo ($IOPS_READ_CLEAN) - provavelmente sistema ocioso")
                CHECK_RESULTS+=("ℹ️ IOPS: ${IOPS_READ_CLEAN} (Sistema ocioso)")
            fi
        else
            echo "  ⚠️ bc não instalado - comparação precisa não disponível"
        fi
    else
        echo "  Nenhum dado de I/O coletado"
        WARNINGS+=("iostat não retornou dados")
    fi
else
    echo "  ⚠️ iostat não instalado - estatísticas ignoradas"
    WARNINGS+=("iostat não instalado")
fi

# 9. PROCESSOS COM I/O
echo -e "\n${BOLD}[9] PROCESSOS COM MAIOR I/O (iotop)${NC}"
if command -v iotop &>/dev/null; then
    IOTOP_OUT=$(timeout 4 iotop -b -n 3 -o -q 2>/dev/null | head -10)
    if [ -n "$IOTOP_OUT" ]; then
        echo "  $IOTOP_OUT"
    else
        echo "  ✅ Nenhum processo com I/O significativo detectado"
    fi
else
    echo "  ⚠️ iotop não instalado - verificação de processos ignorada"
    WARNINGS+=("iotop não instalado")
fi

# 10. VERIFICAÇÃO DE SWAP
echo -e "\n${BOLD}[10] VERIFICAÇÃO DE SWAP E MEMÓRIA (free)${NC}"
if command -v free &>/dev/null; then
    FREE_OUT=$(free -h)
    echo "  $FREE_OUT" | head -2
    SWAP_USED=$(free | grep Swap | awk '{print $3}')
    SWAP_TOTAL=$(free | grep Swap | awk '{print $2}')
    
    if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_PERCENT=$((SWAP_USED * 100 / SWAP_TOTAL))
        if [ $SWAP_PERCENT -gt 80 ]; then
            echo -e "  ${RED}❌ SWAP CRÍTICO: ${SWAP_PERCENT}% usado${NC}"
            PROBLEMS+=("Swap crítico (${SWAP_PERCENT}%) - memória RAM insuficiente")
            CHECK_RESULTS+=("🔴 SWAP: ${SWAP_PERCENT}% (Crítico)")
        elif [ $SWAP_PERCENT -gt 50 ]; then
            echo -e "  ${YELLOW}⚠️  Swap moderado: ${SWAP_PERCENT}% usado${NC}"
            WARNINGS+=("Swap em ${SWAP_PERCENT}%")
            CHECK_RESULTS+=("🟡 SWAP: ${SWAP_PERCENT}% (Moderado)")
        else
            echo -e "  ${GREEN}✅ Swap baixo: ${SWAP_PERCENT}% usado${NC}"
            CHECK_RESULTS+=("✅ SWAP: ${SWAP_PERCENT}% (Baixo)")
        fi
    else
        echo "  ℹ️ Sem partição swap configurada"
        INFO+=("Nenhuma partição swap detectada")
    fi
fi

# 11. DISK SCHEDULER
echo -e "\n${BOLD}[11] AGENDADOR DE I/O (scheduler)${NC}"
for dev in sda nvme0n1; do
    if [ -e /sys/block/$dev/queue/scheduler ]; then
        SCHED=$(cat /sys/block/$dev/queue/scheduler 2>/dev/null | grep -o "\[.*\]" | sed 's/\[//;s/\]//')
        echo "  /dev/$dev: $SCHED"
        
        if [[ "$SCHED" == *"none"* ]] || [[ "$SCHED" == *"noop"* ]]; then
            echo -e "  ${GREEN}✅ Adequado para SSD/NVMe${NC}"
            CHECK_RESULTS+=("✅ SCHEDULER: $SCHED (Adequado)")
        elif [[ "$SCHED" == *"mq-deadline"* ]]; then
            echo -e "  ${GREEN}✅ Bom para uso geral${NC}"
            CHECK_RESULTS+=("✅ SCHEDULER: $SCHED (Bom)")
        elif [[ "$SCHED" == *"cfq"* ]]; then
            echo -e "  ${YELLOW}⚠️  Não recomendado para SSD${NC}"
            WARNINGS+=("Agendador CFQ em SSD - pode reduzir performance")
            CHECK_RESULTS+=("🟡 SCHEDULER: $SCHED (Não recomendado para SSD)")
        fi
    fi
done

# ============================================================
# QUADRO COMPARATIVO FINAL
# ============================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}              QUADRO COMPARATIVO - IDEAL vs DIAGNOSTICADO${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Cabeçalho da tabela
echo -e "\n${BOLD}┌──────────────┬─────────────────────┬─────────────────────┬──────────────┐${NC}"
echo -e "${BOLD}│  COMPONENTE  │      ESPERADO       │    DIAGNOSTICADO    │   STATUS     │${NC}"
echo -e "${BOLD}├──────────────┼─────────────────────┼─────────────────────┼──────────────┤${NC}"

# Linha: Tipo de Disco
DISPLAY_TYPE=$(echo "$DISK_TYPE" | xargs)
EXPECTED_TYPE=$(echo "$DISK_TYPE" | xargs)
if [ -n "$DISPLAY_TYPE" ]; then
    echo "│ Disco        │ $EXPECTED_TYPE         │ $DISPLAY_TYPE         │ ${GREEN}✅ OK${NC}        │"
fi

# Linha: Espaço em disco (pega o resultado mais crítico)
SPACE_CRITICAL=false
for result in "${CHECK_RESULTS[@]}"; do
    if [[ "$result" == *"ESPAÇO"* && "$result" == *"CRÍTICO"* ]]; then
        SPACE_CRITICAL=true
        break
    fi
done

if [ "$SPACE_CRITICAL" = true ]; then
    SPACE_STATUS="${RED}🔴 CRÍTICO${NC}"
elif [ ${#WARNINGS[@]} -gt 0 ] && [[ "${WARNINGS[*]}" == *"Uso de disco"* ]]; then
    SPACE_STATUS="${YELLOW}🟡 ATENÇÃO${NC}"
else
    SPACE_STATUS="${GREEN}✅ OK${NC}"
fi

# Linha: Latência
LATENCY_STATUS=""
for result in "${CHECK_RESULTS[@]}"; do
    if [[ "$result" == *"LATÊNCIA"* ]]; then
        LATENCY_STATUS=$(echo "$result" | awk -F': ' '{print $2
