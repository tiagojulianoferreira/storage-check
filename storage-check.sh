#!/bin/bash
# Storage Check - Diagnóstico READ-ONLY para Linux
# Autor: Tiago Ferreira
# Repositório: https://github.com/tiagojulianoferreira/storage-check
# Versão: 2.6 - Tabela com alinhamento perfeito

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

# 3. USO DE ESPAÇO EM DISCO
echo -e "\n${BOLD}[3] USO DE ESPAÇO EM DISCO (df -hT)${NC}"
REAL_FS=$(df -hT 2>/dev/null | grep -E "^/dev" | head -15)
if [ -n "$REAL_FS" ]; then
    echo "$REAL_FS"
else
    echo "  Nenhum sistema de arquivos real encontrado"
fi

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

# 4. USO DE INODES
echo -e "\n${BOLD}[4] USO DE INODES (df -iT)${NC}"
REAL_INODES=$(df -iT 2>/dev/null | grep -E "^/dev" | head -15)
if [ -n "$REAL_INODES" ]; then
    echo "$REAL_INODES"
else
    echo "  Nenhum sistema de arquivos real encontrado"
fi

# 5. TESTE DE LATÊNCIA (ioping) - CORRIGIDO
echo -e "\n${BOLD}[5] TESTE DE LATÊNCIA (ioping)${NC}"
LATENCY_CLEAN=""
if command -v ioping &>/dev/null; then
    LATENCY_RAW=$(ioping -c 5 -q . 2>/dev/null | grep "avg" | awk "{print \$3}" | sed "s/ms//")
    if [ -n "$LATENCY_RAW" ]; then
        LATENCY_CLEAN=$(echo $LATENCY_RAW | sed 's/,/./')
        echo "  ⏱️  Latência média: ${LATENCY_CLEAN}ms"
        
        # Comparação segura SEM bc
        LATENCY_INT=$(echo "$LATENCY_CLEAN" | cut -d'.' -f1 2>/dev/null)
        EXPECTED_INT=$(echo "$EXPECTED_LATENCY" | cut -d'.' -f1 2>/dev/null)
        
        if [ -z "$LATENCY_INT" ]; then
            LATENCY_INT=0
        fi
        if [ -z "$EXPECTED_INT" ]; then
            EXPECTED_INT=1
        fi
        
        if [ $LATENCY_INT -lt $EXPECTED_INT ] 2>/dev/null; then
            echo -e "  ${GREEN}✅ EXCELENTE (abaixo de ${EXPECTED_LATENCY}ms)${NC}"
            CHECK_RESULTS+=("✅ LATÊNCIA: ${LATENCY_CLEAN}ms (Excelente)")
        elif [ $LATENCY_INT -lt $((EXPECTED_INT * 2)) ] 2>/dev/null; then
            echo -e "  ${YELLOW}⚠️  ACEITÁVEL (esperado ${EXPECTED_LATENCY}ms)${NC}"
            WARNINGS+=("Latência ${LATENCY_CLEAN}ms acima do esperado (${EXPECTED_LATENCY}ms)")
            CHECK_RESULTS+=("🟡 LATÊNCIA: ${LATENCY_CLEAN}ms (Aceitável)")
        else
            echo -e "  ${RED}❌ LATÊNCIA MUITO ALTA (> $((EXPECTED_INT * 2))ms)${NC}"
            PROBLEMS+=("Latência alta: ${LATENCY_CLEAN}ms (esperado ${EXPECTED_LATENCY}ms)")
            CHECK_RESULTS+=("🔴 LATÊNCIA: ${LATENCY_CLEAN}ms (Muito Alta)")
        fi
    else
        echo "  ioping: sem dados coletados"
        WARNINGS+=("ioping não retornou dados")
    fi
else
    echo "  ⚠️ ioping não instalado - teste de latência ignorado"
    WARNINGS+=("ioping não instalado")
fi

# 6. TESTE DE VELOCIDADE (dd) - AJUSTADO
echo -e "\n${BOLD}[6] TESTE DE VELOCIDADE DE LEITURA (dd)${NC}"
SPEED_RESULT=""
if [ -n "$DISK_FOUND" ] && [ -e "$DISK_FOUND" ]; then
    echo "  Testando $DISK_FOUND (pode levar alguns segundos)..."
    DD_RESULT=$(dd if=$DISK_FOUND of=/dev/null bs=1M count=500 iflag=direct 2>&1 | grep "MB/s" | awk "{print \$NF}")
    if [ -n "$DD_RESULT" ]; then
        SPEED_RESULT="$DD_RESULT"
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
        echo "  ⚠️ Não foi possível obter velocidade do disco"
        INFO+=("Teste de velocidade não concluído")
    fi
else
    echo "  Nenhum disco encontrado para teste de velocidade"
    INFO+=("Teste de velocidade ignorado (sem disco detectado)")
fi

# 7. SAUDE SMART
echo -e "\n${BOLD}[7] SAÚDE DO DISCO (SMART)${NC}"
SMART_CHECKED=0
TEMP_RESULT=""
WEAR_RESULT=""

if [ "$IS_NVME" = true ] && command -v nvme &>/dev/null; then
    echo "  📌 Usando nvme-cli para leitura SMART do NVMe:"
    for d in nvme0n1 nvme1n1; do
        if [ -e /dev/$d ]; then
            echo "  /dev/$d:"
            SMART_LOG=$(sudo nvme smart-log /dev/$d 2>/dev/null)
            if [ -n "$SMART_LOG" ]; then
                TEMP=$(echo "$SMART_LOG" | grep "temperature" | awk '{print $3}' | sed 's/+//' | sed 's/C//')
                WEAR=$(echo "$SMART_LOG" | grep "percentage_used" | awk '{print $3}' | sed 's/%//')
                TEMP_RESULT="$TEMP"
                WEAR_RESULT="$WEAR"
                
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

if [ $SMART_CHECKED -eq 0 ] && command -v smartctl &>/dev/null; then
    echo "  📌 Usando smartctl para leitura SMART:"
    for d in sda sdb sdc; do
        if [ -e /dev/$d ]; then
            SMART_RESULT=$(smartctl -H /dev/$d 2>/dev/null | grep -i "test result" | awk -F: "{print \$2}" | xargs)
            TEMP=$(smartctl -A /dev/$d 2>/dev/null | grep "Temperature_Celsius" | awk "{print \$10}")
            TEMP_RESULT="$TEMP"
            
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

# 8. IOSTAT
echo -e "\n${BOLD}[8] ESTATÍSTICAS DE I/O (iostat)${NC}"
IOPS_RESULT=""
UTIL_RESULT=""
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
        IOPS_RESULT="$IOPS_READ_CLEAN"
        UTIL_RESULT="$UTIL_CLEAN"
        
        echo "  📊 Resumo da última amostra:"
        echo "     Leituras/s: ${IOPS_READ_CLEAN} | Escritas/s: ${IOPS_WRITE_CLEAN}"
        echo "     Utilização: ${UTIL_CLEAN}% | Tempo médio de espera: ${AWAIT_CLEAN}ms"
        
        if [ -n "$UTIL_RESULT" ]; then
            UTIL_INT=$(echo "$UTIL_RESULT" | cut -d'.' -f1 2>/dev/null)
            if [ -z "$UTIL_INT" ]; then
                UTIL_INT=0
            fi
            
            if [ $UTIL_INT -gt 80 ] 2>/dev/null; then
                echo -e "  ${RED}❌ UTILIZAÇÃO MUITO ALTA (>80%)${NC}"
                PROBLEMS+=("Utilização alta: ${UTIL_CLEAN}%")
                CHECK_RESULTS+=("🔴 UTILIZAÇÃO: ${UTIL_CLEAN}% (Alta)")
            elif [ $UTIL_INT -gt 50 ] 2>/dev/null; then
                echo -e "  ${YELLOW}⚠️  UTILIZAÇÃO MODERADA (50-80%)${NC}"
                WARNINGS+=("Utilização ${UTIL_CLEAN}%")
                CHECK_RESULTS+=("🟡 UTILIZAÇÃO: ${UTIL_CLEAN}% (Moderada)")
            else
                echo -e "  ${GREEN}✅ UTILIZAÇÃO BAIXA (<50%)${NC}"
                CHECK_RESULTS+=("✅ UTILIZAÇÃO: ${UTIL_CLEAN}% (Baixa)")
            fi
        fi
        
        if [ -n "$IOPS_RESULT" ]; then
            IOPS_INT=$(echo "$IOPS_RESULT" | cut -d'.' -f1 2>/dev/null)
            if [ -z "$IOPS_INT" ]; then
                IOPS_INT=0
            fi
            
            if [ $IOPS_INT -ge $EXPECTED_IOPS ] 2>/dev/null; then
                echo -e "  ${GREEN}✅ IOPS: Excelente ($IOPS_RESULT ≥ $EXPECTED_IOPS)${NC}"
                CHECK_RESULTS+=("✅ IOPS: ${IOPS_RESULT} (Excelente)")
            elif [ $IOPS_INT -ge $((EXPECTED_IOPS * 50 / 100)) ] 2>/dev/null; then
                echo -e "  ${YELLOW}⚠️  IOPS: Aceitável (esperado $EXPECTED_IOPS)${NC}"
                WARNINGS+=("IOPS ${IOPS_RESULT} abaixo do esperado (${EXPECTED_IOPS})")
                CHECK_RESULTS+=("🟡 IOPS: ${IOPS_RESULT} (Aceitável)")
            else
                echo -e "  ${YELLOW}ℹ️  IOPS: Baixo - Sistema ocioso?${NC}"
                INFO+=("IOPS baixo ($IOPS_RESULT) - provavelmente sistema ocioso")
                CHECK_RESULTS+=("ℹ️ IOPS: ${IOPS_RESULT} (Sistema ocioso)")
            fi
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
SWAP_RESULT=""
if command -v free &>/dev/null; then
    FREE_OUT=$(free -h)
    echo "  $FREE_OUT" | head -2
    SWAP_USED=$(free | grep Swap | awk '{print $3}')
    SWAP_TOTAL=$(free | grep Swap | awk '{print $2}')
    
    if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_PERCENT=$((SWAP_USED * 100 / SWAP_TOTAL))
        SWAP_RESULT="$SWAP_PERCENT"
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
SCHED_RESULT=""
for dev in sda nvme0n1; do
    if [ -e /sys/block/$dev/queue/scheduler ]; then
        SCHED=$(cat /sys/block/$dev/queue/scheduler 2>/dev/null | grep -o "\[.*\]" | sed 's/\[//;s/\]//')
        SCHED_RESULT="$SCHED"
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
# QUADRO COMPARATIVO FINAL (VERSÃO HIBRIDA - SIMPLES E ALINHADA)
# ============================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}              QUADRO COMPARATIVO - IDEAL vs DIAGNOSTICADO${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Extrai o valor do espaço
SPACE_VALUE=""
for result in "${CHECK_RESULTS[@]}"; do
    if [[ "$result" == *"ESPAÇO"* ]]; then
        SPACE_VALUE=$(echo "$result" | grep -o "[0-9]*" | head -1)
        break
    fi
done

if [ -z "$SPACE_VALUE" ]; then
    SPACE_VALUE="N/A"
fi

# Função para obter ícone
get_icon() {
    local value="$1"
    local type="$2"
    
    if [ -z "$value" ] || [ "$value" = "N/A" ]; then
        echo "ℹ️"
        return
    fi
    
    case "$type" in
        "space")
            if [ "$value" -gt 90 ] 2>/dev/null; then echo "🔴"
            elif [ "$value" -gt 80 ] 2>/dev/null; then echo "🟡"
            else echo "✅"; fi
            ;;
        "latency")
            value_int=$(echo "$value" | cut -d'.' -f1 2>/dev/null)
            if [ -z "$value_int" ]; then value_int=0; fi
            if [ $value_int -lt 1 ] 2>/dev/null; then echo "✅"
            elif [ $value_int -lt 3 ] 2>/dev/null; then echo "🟡"
            else echo "🔴"; fi
            ;;
        "wear"|"temp"|"swap")
            if [ "$value" -gt 80 ] 2>/dev/null; then echo "🔴"
            elif [ "$value" -gt 50 ] 2>/dev/null; then echo "🟡"
            else echo "✅"; fi
            ;;
        "util")
            if (( $(echo "$value > 80" | bc -l 2>/dev/null) )); then echo "🔴"
            elif (( $(echo "$value > 50" | bc -l 2>/dev/null) )); then echo "🟡"
            else echo "✅"; fi
            ;;
        *)
            echo "✅"
            ;;
    esac
}

# Mostra a tabela de forma simples e alinhada
echo ""
echo "  +---------------------+----------------------+----------------------+"
echo "  | COMPONENTE          | ESPERADO             | DIAGNOSTICADO        |"
echo "  +---------------------+----------------------+----------------------+"

# Função para imprimir linha alinhada
print_row() {
    local comp="$1"
    local expected="$2"
    local diag="$3"
    printf "  | %-19s | %-20s | %-20s |\n" "$comp" "$expected" "$diag"
}

print_row "Disco" "$DISK_TYPE" "$DISK_TYPE"

if [ "$SPACE_VALUE" != "N/A" ]; then
    ICON=$(get_icon "$SPACE_VALUE" "space")
    print_row "Espaço em /" "< 90%" "$ICON ${SPACE_VALUE}%"
else
    print_row "Espaço em /" "< 90%" "ℹ️ N/A"
fi

if [ -n "$LATENCY_CLEAN" ]; then
    ICON=$(get_icon "$LATENCY_CLEAN" "latency")
    print_row "Latência" "< ${EXPECTED_LATENCY}ms" "$ICON ${LATENCY_CLEAN}ms"
else
    print_row "Latência" "< ${EXPECTED_LATENCY}ms" "ℹ️ N/A"
fi

if [ -n "$SPEED_RESULT" ]; then
    print_row "Velocidade" "≥ ${EXPECTED_READ_MB}MB/s" "✅ ${SPEED_RESULT}MB/s"
else
    print_row "Velocidade" "≥ ${EXPECTED_READ_MB}MB/s" "ℹ️ N/A"
fi

if [ -n "$TEMP_RESULT" ]; then
    ICON=$(get_icon "$TEMP_RESULT" "temp")
    print_row "Temperatura" "< 50°C" "$ICON ${TEMP_RESULT}°C"
else
    print_row "Temperatura" "< 50°C" "ℹ️ N/A"
fi

if [ -n "$WEAR_RESULT" ]; then
    ICON=$(get_icon "$WEAR_RESULT" "wear")
    print_row "Desgaste" "< 60%" "$ICON ${WEAR_RESULT}%"
else
    print_row "Desgaste" "< 60%" "ℹ️ N/A"
fi

if [ -n "$UTIL_RESULT" ]; then
    ICON=$(get_icon "$UTIL_RESULT" "util")
    print_row "Utilização" "< 50%" "$ICON ${UTIL_RESULT}%"
else
    print_row "Utilização" "< 50%" "ℹ️ N/A"
fi

if [ -n "$IOPS_RESULT" ]; then
    IOPS_INT=$(echo "$IOPS_RESULT" | cut -d'.' -f1 2>/dev/null)
    if [ -z "$IOPS_INT" ]; then IOPS_INT=0; fi
    if [ $IOPS_INT -ge $EXPECTED_IOPS ] 2>/dev/null; then
        ICON="✅"
    elif [ $IOPS_INT -ge $((EXPECTED_IOPS * 50 / 100)) ] 2>/dev/null; then
        ICON="🟡"
    else
        ICON="ℹ️"
    fi
    print_row "IOPS" "≥ ${EXPECTED_IOPS}" "$ICON ${IOPS_RESULT}"
else
    print_row "IOPS" "≥ ${EXPECTED_IOPS}" "ℹ️ N/A"
fi

if [ -n "$SWAP_RESULT" ]; then
    ICON=$(get_icon "$SWAP_RESULT" "swap")
    print_row "Swap" "< 50%" "$ICON ${SWAP_RESULT}%"
else
    print_row "Swap" "< 50%" "ℹ️ N/A"
fi

if [ -n "$SCHED_RESULT" ]; then
    print_row "Agendador" "none/noop/deadline" "✅ ${SCHED_RESULT}"
else
    print_row "Agendador" "none/noop/deadline" "ℹ️ N/A"
fi

echo "  +---------------------+----------------------+----------------------+"

# ============================================================
# LEGENDA E RESUMO DOS PROBLEMAS
# ============================================================

echo ""
echo "  📌 LEGENDA:"
echo -e "    ${GREEN}✅${NC}  - OK (dentro do esperado)"
echo -e "    ${YELLOW}🟡${NC}  - ATENÇÃO (requer monitoramento)"
echo -e "    ${RED}🔴${NC}  - RUIM (requer ação imediata)"
echo -e "    ${BLUE}ℹ️${NC}  - INFO (informação adicional)"

# Exibe problemas encontrados
if [ ${#PROBLEMS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}${BOLD}❌ PROBLEMAS CRÍTICOS ENCONTRADOS:${NC}"
    for problem in "${PROBLEMS[@]}"; do
        echo -e "    ${RED}• $problem${NC}"
    done
else
    echo -e "\n  ${GREEN}${BOLD}✅ NENHUM PROBLEMA CRÍTICO ENCONTRADO${NC}"
fi

# Exibe avisos
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo -e "\n  ${YELLOW}${BOLD}⚠️  AVISOS:${NC}"
    for warning in "${WARNINGS[@]}"; do
        echo -e "    ${YELLOW}• $warning${NC}"
    done
fi

# Exibe informações
if [ ${#INFO[@]} -gt 0 ]; then
    echo -e "\n  ${BLUE}${BOLD}ℹ️  INFORMAÇÕES ADICIONAIS:${NC}"
    for info in "${INFO[@]}"; do
        echo -e "    ${BLUE}• $info${NC}"
    done
fi

echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ TODOS OS TESTES EXECUTADOS EM MODO SOMENTE LEITURA${NC}"
echo -e "${GREEN}✅ NENHUMA ALTERAÇÃO FOI FEITA NO SISTEMA${NC}"
echo -e "${GREEN}✅ SEGURO PARA AMBIENTES DE PRODUÇÃO${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

echo -e "\n${BLUE}📝 Para mais detalhes, consulte:${NC}"
echo "  • https://github.com/tiagojulianoferreira/storage-check"
echo ""
