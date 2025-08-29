Keterangan :

1. downscale-vm.sh : Cek all VM dengan tags "lb-vmnginx", jika ada VM dengan load CPU kurang dari 20% maka VM tersebut akan di stop kemudian di delete dari proxmox.

2. downscalevm-retry.sh : Cek all VM dengan tags "lb-vmnginx", jika ada VM dengan load CPU dan Memory kurang dari 20% dan pengecekan di retry 3x jika selama 3x pengecekan CPU & Memory kurang dari 20% maka VM akan di stop kemudian dihapus.

3. healthcheck-vm.sh : Cek all VM dengan tags "lb-vmnginx", jika service berjalan normal "hasil sehat 200", jika hasil tidak sehat dan selama 3x pengecekan masih tidak sehat maka VM di stop dan di delete, selanjutnya dilakukan clone ulang VM dari template untuk replace VM yang tidak sehat.

4. upscale-vm.sh : Cek all VM dengan tags "lb-vmnginx", jika semua VM load CPU dan Memory lebih dari 70% akan dilakukan clone dari template dan ditambahkan ke LB.

5. upscalevm-retry.sh : Cek all VM dengan tags "lb-vmnginx", jika semua VM load CPU dan Memory lebih dari 70% akan dilakukan clone dari template dan ditambahkan ke LB. pengecekan dilakukan selama 3x jika dalam 3x pengecekan load masih diatas 70% akan dilakukan upscale penambahan VM untuk load balancer.