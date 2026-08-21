Storage Check - Diagnóstico READ-ONLY para Linux

Ferramenta de diagnóstico de storage para Linux que executa apenas operações de leitura, ideal para ambientes de produção. Fornece métricas de performance, saúde dos discos e recomendações baseadas em referências de mercado.

---

Funcionalidades

Categoria O que faz Comandos utilizados
Descoberta Lista discos, partições, pontos de montagem e tipo de hardware lsblk, fdisk, findmnt
Performance Mede latência, velocidade de leitura e IOPS ioping, dd, hdparm
Saúde Verifica status SMART, temperatura e desgaste (wear level) smartctl
Processos Mostra quais processos estão usando I/O e arquivos abertos iotop, lsof
Estatísticas Exibe utilização, filas de I/O e uso de inodes iostat, df
Benchmark Compara resultados com referências e classifica como ✅ Excelente, ⚠️ Aceitável ou ❌ Ruim Interno

---

Segurança Garantida

· Nenhuma escrita em disco ou sistema de arquivos
· Todos os comandos usam flags de apenas leitura:
  · fsck -n (no-execute)
  · dd iflag=direct (leitura pura, sem cache)
  · smartctl -H (apenas consulta)
· Seguro para produção – pode ser executado em qualquer ambiente sem risco

---

Métricas de Referência Utilizadas

Tipo de Disco Velocidade Leitura IOPS Latência
HDD 7.2K RPM 80-120 MB/s 150 8-12 ms
HDD 10K RPM 120-180 MB/s 200 5-8 ms
HDD 15K RPM 180-250 MB/s 300 3-5 ms
SATA SSD 500-550 MB/s 50K 0.1-1 ms
NVMe SSD 2.000-7.000 MB/s 500K 0.02-0.1 ms

Multiplicadores RAID (leitura):
RAID 0: x2 | RAID 1: x1 | RAID 5: x3 | RAID 6: x4 | RAID 10: x4

---

Comando de Execução (Única Linha)

Copie e cole o comando abaixo no terminal do servidor que deseja diagnosticar:

```bash
bash <(curl -sL https://raw.githubusercontent.com/tiagojulianoferreira/storage-check/main/storage-check.sh)
```

Não requer:

· Download de arquivos
· Criação de scripts
· Conhecimento de shell script
· Permissões de root (embora algumas funções como smartctl precisem de sudo para dados completos)

---

Pré-requisitos

Para funcionamento completo, os seguintes pacotes devem estar instalados:

```bash
# Debian/Ubuntu
sudo apt install -y ioping smartmontools sysstat hdparm lsof util-linux

# RHEL/CentOS
sudo yum install -y ioping smartmontools sysstat hdparm lsof util-linux
```

Se algum pacote não estiver disponível, o script informará e continuará com as demais verificações.

---

Exemplo de Saída

```
=== STORAGE BENCHMARK + HEALTH CHECK (READ-ONLY) ===

[1] DISCOVERY:
  /dev/nvme0n1: SSD/NVMe | RAID: raid0 | Expected Read: 7000MB/s

[2] LATENCY TEST:
  Avg Latency: 0.08ms
  ✅ LATENCY: EXCELLENT

[3] SEQUENTIAL READ TEST:
  Read Speed: 4200MB/s
  ✅ SPEED: EXCELLENT

[4] SMART HEALTH:
  Status: PASSED | Wear: 12% | Temp: 42°C
  ✅ All health checks passed

[5] RECOMMENDATIONS SUMMARY:
  ✅ CRITICAL CHECKS PASSED? (No writes performed)
```

---

Contribuição

Sinta-se à vontade para abrir issues ou pull requests no repositório oficial:
https://github.com/tiagojulianoferreira/storage-check

---

Licença

GPL – Use e modifique livremente.

---
