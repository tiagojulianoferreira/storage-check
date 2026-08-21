bash -c '
echo "=== STORAGE BENCHMARK + HEALTH CHECK (READ-ONLY) ==="
echo "Iniciando coleta de dados..."

# 1. DETECTAR TIPO DE DISCO E RAID
echo -e "\n[1] DISCOVERY:"
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
    
    echo "  /dev/$d: $DISK_TYPE | RAID: $RAID_TYPE | Expected Read: ${EXPECTED_READ_MB}MB/s | IOPS: $EXPECTED_IOPS | Latency: ${EXPECTED_LATENCY}ms"
    break
  fi
done

# 2. TESTE DE LATÊNCIA (ioping)
echo -e "\n[2] LATENCY TEST (ioping):"
if command -v ioping &>/dev/null; then
  LATENCY=$(ioping -c 5 -q . 2>/dev/null | grep "avg" | awk "{print \$3}" | sed "s/ms//")
  if [ -n "$LATENCY" ]; then
    echo "  Avg Latency: ${LATENCY}ms"
    if (( $(echo "$LATENCY < $EXPECTED_LATENCY" | bc -l) )); then
      echo "  ✅ LATENCY: EXCELLENT (below ${EXPECTED_LATENCY}ms)"
    elif (( $(echo "$LATENCY < $EXPECTED_LATENCY * 2" | bc -l) )); then
      echo "  ⚠️  LATENCY: ACCEPTABLE (${EXPECTED_LATENCY}-$((EXPECTED_LATENCY*2))ms)"
    else
      echo "  ❌ LATENCY: POOR (> $((EXPECTED_LATENCY*2))ms) - Check I/O scheduling"
    fi
  else
    echo "  ioping: no data collected"
  fi
else
  echo "  ioping not installed - install with: apt install ioping"
fi

# 3. TESTE DE VELOCIDADE SEQUENCIAL (dd)
echo -e "\n[3] SEQUENTIAL READ TEST (dd):"
if [ -e /dev/sda ]; then
  DD_RESULT=$(dd if=/dev/sda of=/dev/null bs=1M count=1000 iflag=direct 2>&1 | grep "MB/s" | awk "{print \$NF}")
  if [ -n "$DD_RESULT" ]; then
    echo "  Read Speed: ${DD_RESULT}MB/s"
    DD_RATE=$(echo $DD_RESULT | cut -d"." -f1)
    if [ $DD_RATE -ge $EXPECTED_READ_MB ]; then
      echo "  ✅ SPEED: EXCELLENT (≥ ${EXPECTED_READ_MB}MB/s)"
    elif [ $DD_RATE -ge $((EXPECTED_READ_MB * 60 / 100)) ]; then
      echo "  ⚠️  SPEED: ACCEPTABLE (${EXPECTED_READ_MB}MB/s expected)"
    else
      echo "  ❌ SPEED: POOR (< $((EXPECTED_READ_MB * 60 / 100))MB/s) - Check cables/RAID config"
    fi
  fi
else
  echo "  No /dev/sda found - test skipped"
fi

# 4. SAUDE SMART + REFERÊNCIA
echo -e "\n[4] SMART HEALTH + WEAR REFERENCE:"
if command -v smartctl &>/dev/null; then
  for d in sda nvme0n1; do
    if [ -e /dev/$d ]; then
      SMART_RESULT=$(smartctl -H /dev/$d 2>/dev/null | grep -i "test result" | awk -F: "{print \$2}" | xargs)
      WEAR=$(smartctl -A /dev/$d 2>/dev/null | grep -E "Wear_Leveling|Percent_Lifetime|Media_Wearout" | awk "{print \$10}")
      TEMP=$(smartctl -A /dev/$d 2>/dev/null | grep "Temperature_Celsius" | awk "{print \$10}")
      echo "  /dev/$d:"
      echo "    Status: $SMART_RESULT"
      [ -n "$WEAR" ] && echo "    Wear Level: ${WEAR}%"
      [ -n "$TEMP" ] && echo "    Temperature: ${TEMP}°C"
      
      # Referências
      if [ "$SMART_RESULT" = "PASSED" ]; then
        echo "    ✅ SMART: PASSED"
      else
        echo "    ❌ SMART: FAILED - Backup immediately!"
      fi
      
      if [ -n "$TEMP" ] && [ $TEMP -gt 65 ]; then
        echo "    ❌ TEMPERATURE: High (>65°C) - Improve cooling"
      elif [ -n "$TEMP" ] && [ $TEMP -gt 50 ]; then
        echo "    ⚠️  TEMPERATURE: Warm (50-65°C)"
      elif [ -n "$TEMP" ]; then
        echo "    ✅ TEMPERATURE: Good (<50°C)"
      fi
      
      if [ -n "$WEAR" ] && [ $WEAR -gt 80 ]; then
        echo "    ❌ WEAR: Critical (>80%) - Replace disk soon"
      elif [ -n "$WEAR" ] && [ $WEAR -gt 60 ]; then
        echo "    ⚠️  WEAR: Moderate (60-80%) - Monitor closely"
      elif [ -n "$WEAR" ]; then
        echo "    ✅ WEAR: Healthy (<60%)"
      fi
      break
    fi
  done
else
  echo "  smartctl not installed - install with: apt install smartmontools"
fi

# 5. IOSTAT COM REFERÊNCIA
echo -e "\n[5] I/O STATISTICS (iostat):"
if command -v iostat &>/dev/null; then
  iostat -x 1 3 2>/dev/null | grep -E "Device|sd|nvme" | tail -5
  IOPS_READ=$(iostat -x 1 2 2>/dev/null | grep "^sd" | awk "{print \$4}" | head -1)
  UTIL=$(iostat -x 1 2 2>/dev/null | grep "^sd" | awk "{print \$NF}" | head -1)
  
  if [ -n "$IOPS_READ" ]; then
    IOPS_READ_INT=$(echo $IOPS_READ | cut -d"." -f1)
    if [ $IOPS_READ_INT -ge $EXPECTED_IOPS ]; then
      echo "  ✅ IOPS: Excellent ($IOPS_READ_INT ≥ $EXPECTED_IOPS)"
    elif [ $IOPS_READ_INT -ge $((EXPECTED_IOPS * 50 / 100)) ]; then
      echo "  ⚠️  IOPS: Acceptable (${EXPECTED_IOPS} expected)"
    else
      echo "  ❌ IOPS: Low ($IOPS_READ_INT < $EXPECTED_IOPS)"
    fi
  fi
  
  if [ -n "$UTIL" ]; then
    UTIL_INT=$(echo $UTIL | cut -d"." -f1)
    if [ $UTIL_INT -lt 50 ]; then
      echo "  ✅ UTILIZATION: Low ($UTIL_INT%) - Good"
    elif [ $UTIL_INT -lt 80 ]; then
      echo "  ⚠️  UTILIZATION: Moderate ($UTIL_INT%) - Monitor"
    else
      echo "  ❌ UTILIZATION: High ($UTIL_INT%) - Possible bottleneck"
    fi
  fi
else
  echo "  iostat not installed - install with: apt install sysstat"
fi

# 6. REFERÊNCIAS FINAIS COM RECOMENDAÇÕES
echo -e "\n[6] RECOMMENDATIONS SUMMARY:"
echo "========================================"
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
echo "✅ CRITICAL CHECKS PASSED? (No writes performed)"
echo "   - All tests executed in READ-ONLY mode"
echo "   - No modifications to filesystems"
echo "   - Safe for production environments"
echo "=== STORAGE BENCHMARK COMPLETED ==="
'