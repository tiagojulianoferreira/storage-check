#!/bin/bash
# Storage Check - Diagnóstico READ-ONLY para Linux
# Autor: Tiago Ferreira
# Repositório: https://github.com/tiagojulianoferreira/storage-check

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Variáveis para acumular problemas
PROBLEMS=()
WARNINGS=()

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
    
    echo -e "${YELLOW}📦 Installing $package...${NC}"
    
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
            echo -e "${RED}❌ Package manager not found. Please install $package manually.${NC}"
            return 1
            ;;
    esac
    
    if eval $cmd 2>/dev/null; then
        echo -e "${GREEN}✅ $package installed successfully.${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to install $package. Please install manually.${NC}"
        return 1
    fi
}

# ============================================================
# VERIFICAÇÃO DE DEPENDÊNCIAS (UMA CONFIRMAÇÃO ÚNICA)
# ============================================================

echo -e "${BLUE}=== STORAGE CHECK - DEPENDENCY CHECK ===${NC}"
echo ""

# Lista de dependências: comando -> pacote
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
)

# Verifica quais dependências faltam
MISSING=()
for dep in "${dependencies[@]}"; do
    cmd="${dep%:*}"
    pkg="${dep#*:}"
    if ! command -v $cmd &>/dev/null; then
        MISSING+=("$pkg")
    fi
done

# Se houver dependências faltando, pergunta uma única vez
if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Missing dependencies: ${MISSING[*]}${NC}"
    if ask_confirm "Install all missing dependencies?"; then
        for pkg in "${MISSING[@]}"; do
            install_package $pkg
        done
        echo -e "${GREEN}✅ Installation completed.${NC}"
    else
        echo -e "${BLUE}ℹ️  Skipping installation. Some checks will be skipped.${NC}"
        WARNINGS+=("Dependencies not installed: ${MISSING[*]}")
    fi
else
    echo -e "${GREEN}✅ All dependencies are installed.${NC}"
fi

echo ""
echo -e "${GREEN}✅ Dependency check completed. Starting storage analysis...${NC}"
echo ""

# ============================================================
# INÍCIO DA ANÁLISE DE STORAGE (READ-ONLY)
# ============================================================

echo -e "${BLUE}=== STORAGE BENCHMARK + HEALTH CHECK (READ-ONLY) ===${NC}"
echo "Iniciando coleta de dados..."

# 1. DETECTAR TIPO DE DISCO E RAID
echo -e "\n${BLUE}[1] DISCOVERY:${NC}"
EXPECTED_IOPS=0
EXPECTED_LATENCY=0
EXPECTED_READ_MB=0
DISK_FOUND=""

for d in sda sdb sdc nvme0n1 nvme1n1 vda vdb; do
  if [ -e /dev/$d ]; then
    TYPE=$(cat /sys/block/$d/queue/rotational 2>/dev/null)
    if [ "$TYPE" = "0" ]; then
      DISK_TYPE="SSD/NVMe"
      EXPECTED_IOPS=50000
      EXPECTED_LATENCY=0.5
      EXPECTED_READ_MB=500
    elif [ "$TYPE" = "1" ]; then
      DISK_TYPE="HDD"
      EXPECTED_IOPS=150
      EXPECTED_LATENCY=8
      EXPECTED_READ_MB=150
    else
      DISK_TYPE="Unknown"
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
        RAID_TYPE="None"
        RAID_MULTIPLIER=1
      fi
    else
      RAID_TYPE="None"
      RAID_MULTIPLIER=1
    fi
    
    MODEL=$(lsblk -o NAME,MODEL /dev/$d 2>/dev/null | grep "^$d" | awk '{$1=""; print $0}' | xargs)
    SIZE=$(lsblk -o NAME,SIZE /dev/$d 2>/dev/null | grep "^$d" | awk '{print $2}')
    
    echo "  /dev/$d: $DISK_TYPE | $SIZE | $MODEL"
    echo "    RAID: $RAID_TYPE | Expected Read: ${EXPECTED_READ_MB}MB/s | IOPS: $EXPECTED_IOPS | Latency: ${EXPECTED_LATENCY}ms"
    DISK_FOUND="/dev/$d"
    break
  fi
done

if [ -z "$DISK_FOUND" ]; then
    echo "  ⚠️ No disk found!"
    PROBLEMS+=("No disk detected")
fi

# 2. LISTAR PARTIÇÕES E PONTOS DE MONTAGEM
echo -e "\n${BLUE}[2] PARTITIONS & MOUNTPOINTS:${NC}"
if command -v lsblk &>/dev/null; then
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,ROTA 2>/dev/null | grep -v "loop" | head -20
else
    echo "  ⚠️ lsblk not available"
    WARNINGS+=("lsblk not installed")
fi

# 3. USO DE ESPAÇO E INODES
echo -e "\n${BLUE}[3] FILESYSTEM USAGE:${NC}"
df -hT 2>/dev/null | grep -v "tmpfs" | head -15
echo ""
df -iT 2>/dev/null | grep -v "tmpfs" | head -15

# Verifica uso de espaço > 90%
DF_OUTPUT=$(df -hT 2>/dev/null | grep -v "tmpfs" | awk 'NR>1 {print $7, $6}' | sed 's/%//')
while read -r mount usage; do
    if [ -n "$usage" ] && [ "$usage" -gt 90 ] 2>/dev/null; then
        PROBLEMS+=("Disk usage at ${usage}% on $mount (critical)")
    elif [ -n "$usage" ] && [ "$usage" -gt 80 ] 2>/dev/null; then
        WARNINGS+=("Disk usage at ${usage}% on $mount")
    fi
done <<< "$DF_OUTPUT"

# 4. TESTE DE LATÊNCIA (ioping) - CORRIGIDO
echo -e "\n${BLUE}[4] LATENCY TEST (ioping):${NC}"
if command -v ioping &>/dev/null; then
  LATENCY_RAW=$(ioping -c 5 -q . 2>/dev/null | grep "avg" | awk "{print \$3}" | sed "s/ms//")
  if [ -n "$LATENCY_RAW" ]; then
    echo "  Avg Latency: ${LATENCY_RAW}ms"
    
    # Remove vírgula e converte para inteiro para comparação segura
    LATENCY_INT=$(echo $LATENCY_RAW | sed 's/,/./' | cut -d'.' -f1 2>/dev/null)
    EXPECTED_INT=$(echo $EXPECTED_LATENCY | cut -d'.' -f1 2>/dev/null)
    
    # Fallback se não conseguir extrair inteiro
    if [ -z "$LATENCY_INT" ]; then
        LATENCY_INT=0
    fi
    if [ -z "$EXPECTED_INT" ]; then
        EXPECTED_INT=1
    fi
    
    # Comparação segura (sem bc)
    if [ $LATENCY_INT -lt $EXPECTED_INT ] 2>/dev/null; then
        echo -e "  ${GREEN}✅ LATENCY: EXCELLENT (below ${EXPECTED_LATENCY}ms)${NC}"
    elif [ $LATENCY_INT -lt $((EXPECTED_INT * 2)) ] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠️  LATENCY: ACCEPTABLE (${EXPECTED_LATENCY}-$((EXPECTED_INT*2))ms)${NC}"
    else
        echo -e "  ${RED}❌ LATENCY: POOR (> $((EXPECTED_INT*2))ms) - Check I/O scheduling${NC}"
        PROBLEMS+=("High latency: ${LATENCY_RAW}ms (expected ${EXPECTED_LATENCY}ms)")
    fi
  else
    echo "  ioping: no data collected"
    WARNINGS+=("ioping returned no data")
  fi
else
  echo "  ⚠️ ioping not installed - latency test skipped"
  WARNINGS+=("ioping not installed")
fi

# 5. TESTE DE VELOCIDADE SEQUENCIAL (dd)
echo -e "\n${BLUE}[5] SEQUENTIAL READ TEST (dd):${NC}"
if [ -e /dev/sda ]; then
  DD_RESULT=$(dd if=/dev/sda of=/dev/null bs=1M count=500 iflag=direct 2>&1 | grep "MB/s" | awk "{print \$NF}")
  if [ -n "$DD_RESULT" ]; then
    echo "  Read Speed: ${DD_RESULT}MB/s"
    DD_RATE=$(echo $DD_RESULT | cut -d"." -f1 2>/dev/null)
    if [ -n "$DD_RATE" ] && [ $DD_RATE -ge $EXPECTED_READ_MB ] 2>/dev/null; then
      echo -e "  ${GREEN}✅ SPEED: EXCELLENT (≥ ${EXPECTED_READ_MB}MB/s)${NC}"
    elif [ -n "$DD_RATE" ] && [ $DD_RATE -ge $((EXPECTED_READ_MB * 60 / 100)) ] 2>/dev/null; then
      echo -e "  ${YELLOW}⚠️  SPEED: ACCEPTABLE (${EXPECTED_READ_MB}MB/s expected)${NC}"
      WARNINGS+=("Read speed ${DD_RESULT}MB/s below expected ${EXPECTED_READ_MB}MB/s")
    elif [ -n "$DD_RATE" ]; then
      echo -e "  ${RED}❌ SPEED: POOR (< $((EXPECTED_READ_MB * 60 / 100))MB/s) - Check cables/RAID config${NC}"
      PROBLEMS+=("Low read speed: ${DD_RESULT}MB/s")
    fi
  fi
else
  echo "  No /dev/sda found - test skipped"
fi

# 6. SAUDE SMART - CORRIGIDO (trata Status vazio)
echo -e "\n${BLUE}[6] SMART HEALTH + WEAR REFERENCE:${NC}"
SMART_CHECKED=0
if command -v smartctl &>/dev/null; then
  for d in sda nvme0n1; do
    if [ -e /dev/$d ]; then
      SMART_RESULT=$(smartctl -H /dev/$d 2>/dev/null | grep -i "test result" | awk -F: "{print \$2}" | xargs)
      WEAR=$(smartctl -A /dev/$d 2>/dev/null | grep -E "Wear_Leveling|Percent_Lifetime|Media_Wearout" | awk "{print \$10}")
      TEMP=$(smartctl -A /dev/$d 2>/dev/null | grep "Temperature_Celsius" | awk "{print \$10}")
      echo "  /dev/$d:"
      
      # Se SMART_RESULT estiver vazio, tenta buscar outras informações
      if [ -z "$SMART_RESULT" ]; then
        # Tenta obter o resultado de forma alternativa
        SMART_RESULT=$(smartctl -H /dev/$d 2>/dev/null | grep -i "overall-health" | awk -F: "{print \$2}" | xargs)
        if [ -z "$SMART_RESULT" ]; then
            SMART_RESULT="UNAVAILABLE"
        fi
      fi
      
      echo "    Status: $SMART_RESULT"
      [ -n "$WEAR" ] && echo "    Wear Level: ${WEAR}%"
      [ -n "$TEMP" ] && echo "    Temperature: ${TEMP}°C"
      
      # Avaliação do SMART
      if echo "$SMART_RESULT" | grep -qi "passed"; then
        echo -e "    ${GREEN}✅ SMART: PASSED${NC}"
      elif echo "$SMART_RESULT" | grep -qi "unavailable"; then
        echo -e "    ${YELLOW}⚠️  SMART: UNAVAILABLE - Check permissions or disk support${NC}"
        WARNINGS+=("SMART unavailable on /dev/$d")
      else
        echo -e "    ${RED}❌ SMART: FAILED or UNKNOWN - Backup immediately!${NC}"
        PROBLEMS+=("SMART failed on /dev/$d (status: $SMART_RESULT)")
      fi
      
      # Temperatura
      if [ -n "$TEMP" ] && [ $TEMP -gt 65 ] 2>/dev/null; then
        echo -e "    ${RED}❌ TEMPERATURE: High (>65°C) - Improve cooling${NC}"
        PROBLEMS+=("High temperature (${TEMP}°C) on /dev/$d")
      elif [ -n "$TEMP" ] && [ $TEMP -gt 50 ] 2>/dev/null; then
        echo -e "    ${YELLOW}⚠️  TEMPERATURE: Warm (50-65°C)${NC}"
        WARNINGS+=("Temperature ${TEMP}°C on /dev/$d")
      elif [ -n "$TEMP" ]; then
        echo -e "    ${GREEN}✅ TEMPERATURE: Good (<50°C)${NC}"
      fi
      
      # Wear Level
      if [ -n "$WEAR" ] && [ $WEAR -gt 80 ] 2>/dev/null; then
        echo -e "    ${RED}❌ WEAR: Critical (>80%) - Replace disk soon${NC}"
        PROBLEMS+=("Wear level ${WEAR}% on /dev/$d")
      elif [ -n "$WEAR" ] && [ $WEAR -gt 60 ] 2>/dev/null; then
        echo -e "    ${YELLOW}⚠️  WEAR: Moderate (60-80%) - Monitor closely${NC}"
        WARNINGS+=("Wear level ${WEAR}% on /dev/$d")
      elif [ -n "$WEAR" ]; then
        echo -e "    ${GREEN}✅ WEAR: Healthy (<60%)${NC}"
      fi
      SMART_CHECKED=1
      break
    fi
  done
  if [ $SMART_CHECKED -eq 0 ]; then
    echo "  No SMART-capable disk found"
    WARNINGS+=("No SMART data available")
  fi
else
  echo "  ⚠️ smartctl not installed - health check skipped"
  WARNINGS+=("smartctl not installed")
fi

# 7. IOSTAT COM REFERÊNCIA
echo -e "\n${BLUE}[7] I/O STATISTICS (iostat):${NC}"
if command -v iostat &>/dev/null; then
  iostat -x 1 3 2>/dev/null | grep -E "Device|sd|nvme" | tail -10
  
  IOPS_READ=$(iostat -x 1 2 2>/dev/null | grep "^sd\|^nvme" | awk "{print \$4}" | head -1)
  UTIL=$(iostat -x 1 2 2>/dev/null | grep "^sd\|^nvme" | awk "{print \$NF}" | head -1)
  
  if [ -n "$IOPS_READ" ]; then
    IOPS_READ_INT=$(echo $IOPS_READ | cut -d"." -f1 2>/dev/null)
    if [ -n "$IOPS_READ_INT" ] && [ $IOPS_READ_INT -ge $EXPECTED_IOPS ] 2>/dev/null; then
      echo -e "  ${GREEN}✅ IOPS: Excellent ($IOPS_READ_INT ≥ $EXPECTED_IOPS)${NC}"
    elif [ -n "$IOPS_READ_INT" ] && [ $IOPS_READ_INT -ge $((EXPECTED_IOPS * 50 / 100)) ] 2>/dev/null; then
      echo -e "  ${YELLOW}⚠️  IOPS: Acceptable (${EXPECTED_IOPS} expected)${NC}"
      WARNINGS+=("IOPS ${IOPS_READ_INT} below expected ${EXPECTED_IOPS}")
    elif [ -n "$IOPS_READ_INT" ]; then
      echo -e "  ${RED}❌ IOPS: Low ($IOPS_READ_INT < $EXPECTED_IOPS)${NC}"
      PROBLEMS+=("Low IOPS: ${IOPS_READ_INT}")
    fi
  fi
  
  if [ -n "$UTIL" ]; then
    UTIL_INT=$(echo $UTIL | cut -d"." -f1 2>/dev/null)
    if [ -n "$UTIL_INT" ] && [ $UTIL_INT -lt 50 ] 2>/dev/null; then
      echo -e "  ${GREEN}✅ UTILIZATION: Low ($UTIL_INT%) - Good${NC}"
    elif [ -n "$UTIL_INT" ] && [ $UTIL_INT -lt 80 ] 2>/dev/null; then
      echo -e "  ${YELLOW}⚠️  UTILIZATION: Moderate ($UTIL_INT%) - Monitor${NC}"
      WARNINGS+=("Utilization ${UTIL_INT}%")
    elif [ -n "$UTIL_INT" ]; then
      echo -e "  ${RED}❌ UTILIZATION: High ($UTIL_INT%) - Possible bottleneck${NC}"
      PROBLEMS+=("High utilization ${UTIL_INT}%")
    fi
  fi
else
  echo "  ⚠️ iostat not installed - statistics skipped"
  WARNINGS+=("iostat not installed")
fi

# 8. PROCESSOS COM I/O
echo -e "\n${BLUE}[8] TOP I/O PROCESSES (iotop):${NC}"
if command -v iotop &>/dev/null; then
  timeout 4 iotop -b -n 3 -o -q 2>/dev/null | head -15 || echo "  No I/O activity detected"
else
  echo "  ⚠️ iotop not installed - process I/O check skipped"
  WARNINGS+=("iotop not installed")
fi

# 9. ARQUIVOS ABERTOS
echo -e "\n${BLUE}[9] OPEN FILES (lsof):${NC}"
if command -v lsof &>/dev/null; then
  lsof 2>/dev/null | head -10 || echo "  No files open"
else
  echo "  ⚠️ lsof not installed - open files check skipped"
  WARNINGS+=("lsof not installed")
fi

# 10. VERIFICAÇÃO DE INTEGRIDADE (READ-ONLY)
echo -e "\n${BLUE}[10] FILESYSTEM CHECK (read-only):${NC}"
if [ -e /dev/sda1 ]; then
  fsck -n /dev/sda1 2>/dev/null | head -6 || echo "  fsck check completed (read-only)"
else
  echo "  No /dev/sda1 found - check skipped"
fi

# 11. SCHEDULER INFO
echo -e "\n${BLUE}[11] DISK SCHEDULER:${NC}"
for dev in sda nvme0n1; do
  if [ -e /sys/block/$dev/queue/scheduler ]; then
    SCHED=$(cat /sys/block/$dev/queue/scheduler 2>/dev/null | grep -o "\[.*\]" | sed 's/\[//;s/\]//')
    echo "  /dev/$dev: $SCHED"
  fi
done

# ============================================================
# RESUMO FINAL COM DESTAQUE DOS PROBLEMAS
# ============================================================

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}[12] RECOMMENDATIONS SUMMARY:${NC}"
echo "REFERENCE TABLE:"
echo "  HDD 7.2K: 80-120 MB/s | 150 IOPS | 8-12ms latency"
echo "  HDD 10K:  120-180 MB/s | 200 IOPS | 5-8ms latency"
echo "  HDD 15K:  180-250 MB/s | 300 IOPS | 3-5ms latency"
echo "  SATA SSD: 500-550 MB/s | 50K IOPS | 0.1-1ms latency"
echo "  NVMe:     2000-7000 MB/s | 500K IOPS | 0.02-0.1ms latency"
echo ""
echo "RAID MULTIPLIERS (Read):"
echo "  RAID 0: x2 | RAID 1: x1 | RAID 5: x3 | RAID 6: x4 | RAID 10: x4"
echo "========================================"

# Exibe problemas encontrados
if [ ${#PROBLEMS[@]} -gt 0 ]; then
    echo -e "\n${RED}${BOLD}❌ CRITICAL ISSUES FOUND:${NC}"
    for problem in "${PROBLEMS[@]}"; do
        echo -e "  ${RED}• $problem${NC}"
    done
else
    echo -e "\n${GREEN}✅ No critical issues found.${NC}"
fi

# Exibe avisos
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}⚠️  WARNINGS:${NC}"
    for warning in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}• $warning${NC}"
    done
fi

echo -e "\n${GREEN}✅ CRITICAL CHECKS PASSED? (No writes performed)${NC}"
echo "   - All tests executed in READ-ONLY mode"
echo "   - No modifications to filesystems"
echo "   - Safe for production environments"
echo -e "${BLUE}=== STORAGE BENCHMARK COMPLETED ===${NC}"
