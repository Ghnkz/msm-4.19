#!/usr/bin/env bash
# ============================================================
# Start Naughty - kernel build script (converted from GitHub Actions)
# ============================================================
set -e
set -o pipefail

# ----- Config: adjust these to match your setup -----
KERNEL_DIR="$(pwd)"          # assumes this script runs from inside the kernel source tree
LOG_FILE="$KERNEL_DIR/build_error.log"

# ============================================================
# Fungsi upload generik ke Gofile (dipakai untuk zip & error log)
# ============================================================
upload_to_gofile() {
  local FILE_TO_UPLOAD="$1"

  if [ ! -f "$FILE_TO_UPLOAD" ]; then
    echo "!! File '${FILE_TO_UPLOAD}' tidak ditemukan, upload dibatalkan."
    return 1
  fi

  echo "==> Mengupload ${FILE_TO_UPLOAD} ke Gofile..."

  GOFILE_SERVER="$(curl -s https://api.gofile.io/servers | grep -o '"name":"[a-zA-Z0-9]*"' | head -n1 | cut -d'"' -f4)"

  if [ -z "$GOFILE_SERVER" ]; then
    echo "!! Gagal mendapatkan server Gofile, upload dibatalkan."
    return 1
  fi

  UPLOAD_RESPONSE="$(curl -s -F "file=@${FILE_TO_UPLOAD}" "https://${GOFILE_SERVER}.gofile.io/uploadFile")"
  echo "$UPLOAD_RESPONSE"

  DOWNLOAD_PAGE="$(echo "$UPLOAD_RESPONSE" | grep -o '"downloadPage":"[^"]*"' | cut -d'"' -f4 | sed 's/\\\//\//g')"

  if [ -n "$DOWNLOAD_PAGE" ]; then
    echo "==> Upload berhasil! Link download: $DOWNLOAD_PAGE"
  else
    echo "!! Upload gagal atau format respons Gofile berubah, cek UPLOAD_RESPONSE di atas."
    return 1
  fi
}

# ============================================================
# Fungsi dipanggil jika build gagal (dipasang lewat trap ERR)
# ============================================================
on_build_error() {
  echo "==> !! Build GAGAL. Mengupload error log ke Gofile..."
  upload_to_gofile "$LOG_FILE"
  exit 1
}

# Jika folder "clang" sudah ada, anggap toolchain (clang/gcc64/gcc32/KernelSU-Next)
# sudah pernah disiapkan sebelumnya -> skip tahap timezone/deps/toolchain/KernelSU-Next.
# (folder "clang" dihapus otomatis di akhir script kalau build sukses, lihat
# bagian cleanup, jadi kalau folder ini tidak ada berarti memang perlu setup ulang.)
if [ -d "$KERNEL_DIR/clang" ]; then
  SKIP_SETUP=1
  echo "==> Folder 'clang' terdeteksi, melewati tahap setup (timezone/deps/toolchain/KernelSU-Next)"
else
  SKIP_SETUP=0
fi

# defconfig HANYA di-skip kalau out/.config benar-benar sudah ada.
# Ini dicek terpisah dari SKIP_SETUP di atas, karena folder "out" bisa saja
# sudah terbuat (misal dari run sebelumnya yang gagal di tengah jalan) tanpa
# defconfig sempat sukses -> kalau cuma cek folder "out" doang, defconfig bisa
# ke-skip padahal .config belum pernah ada, dan build akan gagal dengan error
# "Configuration file .config not found!".
if [ -f "$KERNEL_DIR/out/.config" ]; then
  NEED_DEFCONFIG=0
  echo "==> out/.config terdeteksi, melewati defconfig (incremental build)"
else
  NEED_DEFCONFIG=1
fi

# ============================================================
# 🧭 Pilih Clang yang mau dipakai
# ============================================================
# Bisa dipilih lewat variabel CLANG_CHOICE (untuk CI / non-interaktif),
# atau lewat menu interaktif kalau tidak diset. Pilihan yang tersedia:
#   1) Proton Clang 13   -> resmi, kdrag0n/proton-clang (LLVM+Clang 13.0.0)
#   2) Proton Clang 20   -> Proton Clang resmi berhenti di Clang 13 (2021) dan
#                           tidak pernah merilis versi 20, jadi opsi ini memakai
#                           WeebX-Clang build "20.0.0git" sebagai pengganti yang
#                           setara (tetap toolchain clang berbasis LLVM 20).
#   3) Google Clang      -> prebuilt clang resmi dari AOSP
#                           (android.googlesource.com/platform/prebuilts/clang/host/linux-x86)
#   4) Neutron Clang 24  -> Neutron Clang adalah rolling release (tidak punya
#                           tag versi "24" yang fix), disinkronkan lewat AntMan
#                           sehingga akan mengambil build clang terbaru yang tersedia.
#   5) ZyCromerZ Clang 17.0.0-20230725 -> toolchain yang dipakai script versi awal
#                           (sebelum ada menu pilihan ini), tetap disediakan sebagai opsi.
select_clang() {
  if [ -z "${CLANG_CHOICE:-}" ]; then
    if [ -t 0 ]; then
      echo "==> Pilih toolchain Clang yang ingin dipakai:"
      select opt in "Proton Clang 13" "Proton Clang 20" "Google Clang" "Neutron Clang 24" "ZyCromerZ Clang 17.0.0-20230725"; do
        case "$REPLY" in
          1|2|3|4|5) CLANG_CHOICE="$REPLY"; break ;;
          *) echo "Pilihan tidak valid, coba lagi." ;;
        esac
      done
    else
      echo "==> Tidak ada input interaktif dan CLANG_CHOICE tidak diset, default ke Proton Clang 13."
      CLANG_CHOICE=1
    fi
  fi

  CLANG_DIR="$KERNEL_DIR/clang"

  case "$CLANG_CHOICE" in
    1)
      echo "==> Menyiapkan Proton Clang 13 (kdrag0n/proton-clang)..."
      git clone --depth=1 https://github.com/kdrag0n/proton-clang "$CLANG_DIR"
      CLANG_BIN_DIR="$CLANG_DIR/bin"
      ;;
    2)
      echo "==> Menyiapkan Proton Clang 20 (via WeebX-Clang 20.0.0git, pengganti karena Proton Clang resmi mandek di Clang 13)..."
      mkdir -p "$CLANG_DIR"
      DL_URL="$(curl -s "https://api.github.com/repos/XSans0/WeebX-Clang/releases/tags/WeebX-Clang-20.0.0git-release" \
        | grep -o '"browser_download_url": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
      if [ -z "$DL_URL" ]; then
        echo "!! Gagal mendapatkan link download WeebX-Clang 20. Cek koneksi/rilis di GitHub."
        exit 1
      fi
      wget -O "$CLANG_DIR/clang20.tar.gz" "$DL_URL"
      tar -xf "$CLANG_DIR/clang20.tar.gz" -C "$CLANG_DIR"
      rm -f "$CLANG_DIR/clang20.tar.gz"
      CLANG_BIN_DIR="$CLANG_DIR/bin"
      ;;
    3)
      echo "==> Menyiapkan Google Clang (prebuilt AOSP, ambil folder clang-r terbaru)..."
      git clone --depth=1 --filter=blob:none --no-checkout \
        https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 "$CLANG_DIR"
      (
        cd "$CLANG_DIR"
        LATEST_SUBDIR="$(git ls-tree -d --name-only HEAD | grep '^clang-r' | sort -V | tail -n1)"
        git sparse-checkout init --cone
        git sparse-checkout set "$LATEST_SUBDIR"
        git checkout
        echo "$LATEST_SUBDIR" > .clang_subdir
      )
      CLANG_SUBDIR="$(cat "$CLANG_DIR/.clang_subdir")"
      CLANG_BIN_DIR="$CLANG_DIR/$CLANG_SUBDIR/bin"
      ;;
    4)
      echo "==> Menyiapkan Neutron Clang (rolling release via AntMan, dilabeli 'Neutron Clang 24')..."
      mkdir -p "$CLANG_DIR"
      (
        cd "$CLANG_DIR"
        curl -LSs -o antman "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
        chmod +x antman
        ./antman -S
      )
      CLANG_BIN_DIR="$CLANG_DIR/bin"
      ;;
    5)
      echo "==> Menyiapkan ZyCromerZ Clang 17.0.0-20230725..."
      mkdir -p "$CLANG_DIR"
      wget -O "$CLANG_DIR/Clang-17.0.0-20230725.tar.gz" \
        "https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-20230725-release/Clang-17.0.0-20230725.tar.gz"
      tar -xzf "$CLANG_DIR/Clang-17.0.0-20230725.tar.gz" -C "$CLANG_DIR"
      rm -f "$CLANG_DIR/Clang-17.0.0-20230725.tar.gz"
      CLANG_BIN_DIR="$CLANG_DIR/bin"
      ;;
    *)
      echo "!! CLANG_CHOICE='$CLANG_CHOICE' tidak dikenal. Gunakan 1-5."
      exit 1
      ;;
  esac

  # Simpan path bin toolchain supaya bisa dipakai lagi walau script dijalankan
  # ulang tanpa perlu memilih ulang (dibaca saat SKIP_SETUP=1).
  echo "$CLANG_BIN_DIR" > "$KERNEL_DIR/.clang_bin_dir"
}

# Catat file yang sudah di-tracking git (dan statusnya) SEBELUM setup,
# supaya nanti bisa tahu file mana saja yang diubah oleh curl/setup.sh
# dan bisa dikembalikan (restore) setelah build sukses.
#
# CATATAN PENTING (devcontainer/Codespaces): git sering menolak repo dengan
# error "detected dubious ownership in repository" kalau owner folder beda
# dari user yang menjalankan git (umum terjadi di /workspaces/...). Kalau
# ini terjadi, `git rev-parse --is-inside-work-tree` gagal DIAM-DIAM (tanpa
# pesan error yang terlihat, karena outputnya dibuang) sehingga fitur
# restore ini tidak pernah jalan. Baris di bawah menandai folder ini aman
# supaya git mau bekerja normal.
git config --global --add safe.directory "$KERNEL_DIR" 2>/dev/null || true

GIT_AVAILABLE=0
if git -C "$KERNEL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_AVAILABLE=1
  echo "==> Git terdeteksi di $KERNEL_DIR, fitur restore file KernelSU-Next aktif."
else
  echo "==> !! Git TIDAK terdeteksi/tidak bisa dipakai di $KERNEL_DIR (bukan repo git, atau bermasalah)."
  echo "    -> File yang diedit oleh setup.sh KernelSU-Next TIDAK akan bisa dikembalikan otomatis."
fi

if [ "$SKIP_SETUP" -eq 0 ]; then
  # Snapshot file untracked SEBELUM setup.sh, supaya nanti bisa dibedakan
  # mana file baru yang murni muncul akibat setup.sh KernelSU-Next.
  if [ "$GIT_AVAILABLE" -eq 1 ]; then
    UNTRACKED_BEFORE_SETUP="$(git -C "$KERNEL_DIR" status --porcelain | awk '/^\?\?/ {print $2}')"
  fi

  # ===== ⏰ Prepare timezone =====
  echo "==> Setting timezone to Asia/Jakarta"
  sudo rm -f /etc/localtime
  sudo ln -s /usr/share/zoneinfo/Asia/Jakarta /etc/localtime

  # ===== 📦 Install Dependencies =====
  echo "==> Installing dependencies"
  sudo apt update -y
  sudo apt install -y bc cpio flex bison aptitude git python-is-python3 tar aria2 perl wget curl lz4 libssl-dev

  # ===== 🔧 Clone Toolchains =====
  echo "==> Cloning toolchains"
  if [ -d "$KERNEL_DIR/clang" ]; then
    echo "Clang toolchain already exists, skipping..."
  else
    select_clang
  fi

  if [ -d "$KERNEL_DIR/gcc64" ]; then
    echo "gcc64 toolchain already exists, skipping..."
  else
    git clone https://github.com/greenforce-project/gcc-arm64 -b main --depth=1 gcc64
  fi

  if [ -d "$KERNEL_DIR/gcc32" ]; then
    echo "gcc32 toolchain already exists, skipping..."
  else
    git clone https://github.com/greenforce-project/gcc-arm -b main --depth=1 gcc32
  fi

  # ===== KERNELSU-NEXT SETUP =====
  if [ -d "${KERNEL_DIR}/KernelSU-Next" ]; then
    echo "KernelSU-Next folder already exists, skipping setup..."
  else
    curl -LSs "https://raw.githubusercontent.com/Ghnkz-hub/KernelSU-Next/stable/kernel/setup.sh" | bash -s syscall
  fi

  # Simpan daftar file yang berubah (tracked) akibat setup.sh KernelSU-Next,
  # supaya nanti bisa dikembalikan setelah build sukses.
  if [ "$GIT_AVAILABLE" -eq 1 ]; then
    MODIFIED_BY_SETUP="$(git -C "$KERNEL_DIR" diff --name-only)"

    # File baru (untracked) yang muncul SETELAH setup.sh dan belum ada
    # SEBELUM setup.sh -> ini murni hasil setup.sh, aman untuk dihapus saat
    # cleanup (folder KernelSU-Next sendiri sudah ditangani terpisah di
    # bagian cleanup, jadi ini menangkap sisa file lain kalau ada, mis. file
    # yang ditaruh setup.sh di luar folder KernelSU-Next/).
    UNTRACKED_AFTER_SETUP="$(git -C "$KERNEL_DIR" status --porcelain | awk '/^\?\?/ {print $2}')"
    NEW_FILES_BY_SETUP="$(comm -13 \
      <(printf '%s\n' "$UNTRACKED_BEFORE_SETUP" | sort) \
      <(printf '%s\n' "$UNTRACKED_AFTER_SETUP" | sort) \
      | grep -v '^$' \
      | grep -vE '^(clang|gcc64|gcc32|KernelSU-Next|AnyKernel|out)(/|$)' || true)"

    if [ -n "$MODIFIED_BY_SETUP" ]; then
      echo "==> File tracked yang diubah setup.sh KernelSU-Next:"
      echo "$MODIFIED_BY_SETUP"
    fi
    if [ -n "$NEW_FILES_BY_SETUP" ]; then
      echo "==> File baru (untracked) yang ditambahkan setup.sh KernelSU-Next:"
      echo "$NEW_FILES_BY_SETUP"
    fi
  else
    MODIFIED_BY_SETUP=""
    NEW_FILES_BY_SETUP=""
  fi
else
  echo "==> Setup dilewati. Pastikan folder clang/, gcc64/, gcc32/, dan KernelSU-Next/ sudah lengkap dari build sebelumnya."
  MODIFIED_BY_SETUP=""
  NEW_FILES_BY_SETUP=""
fi

# ===== ⚙️ Setup Environment =====
echo "==> Setting up environment variables"
export BUILD_TIME="$(TZ=Asia/Jakarta date '+%d%m%Y-%H%M')"

# Path bin clang tergantung toolchain yang dipilih (Proton/Google/Neutron
# punya struktur folder berbeda), makanya dibaca dari file yang disimpan
# oleh select_clang di atas.
if [ -f "$KERNEL_DIR/.clang_bin_dir" ]; then
  CLANG_BIN_DIR="$(cat "$KERNEL_DIR/.clang_bin_dir")"
else
  CLANG_BIN_DIR="$KERNEL_DIR/clang/bin"
fi
export CLANG_PATH="$KERNEL_DIR/clang"
export GCC64_PATH="$KERNEL_DIR/gcc64"
export GCC32_PATH="$KERNEL_DIR/gcc32"
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export STRIP=llvm-strip

# ===== 📅 Set BUILD DATE =====
export BUILD_DATE="\"$(TZ=Asia/Jakarta date '+%b %d %Y')\""

# ===== 🛠️ Build Kernel =====
echo "==> Building kernel"
export ARCH=arm64
export PATH="$CLANG_BIN_DIR:$GCC64_PATH/bin:$GCC32_PATH/bin:$PATH"
export KBUILD_BUILD_USER=Ghnkz
export KBUILD_BUILD_HOST=AmeMikana
export KBUILD_COMPILER_STRING="$("$CLANG_BIN_DIR/clang" --version | head -n1)"
export CFLAGS_EXTRA="-DBUILD_DATE=$BUILD_DATE"

# Fix: host tool (fixdep, dll) dilink pakai HOSTCC (gcc) yang secara default
# mencari 'ld' polos di PATH. Karena $CLANG_BIN_DIR ada di depan PATH, 'ld'
# yang kepakai adalah ld/bfd lama bawaan toolchain clang, yang error kalau
# glibc host (mis. Ubuntu di devcontainer) sudah pakai section RELR
# (".relr.dyn", error "unknown type [0x13] section"). Paksa pakai ld.lld
# bawaan toolchain yang sudah cukup baru untuk paham RELR.
if command -v ld.lld >/dev/null 2>&1; then
  export HOSTLDFLAGS="-fuse-ld=lld"
fi

# Mulai dari sini, jika ada error, on_build_error akan dipanggil otomatis
# (upload error log ke Gofile) lalu script berhenti.
trap on_build_error ERR

# defconfig hanya perlu dijalankan sekali (saat out/.config belum ada).
# Kalau out/.config sudah ada, make akan otomatis melakukan incremental build
# berdasarkan .config yang sudah tersimpan di dalamnya.
if [ "$NEED_DEFCONFIG" -eq 1 ]; then
  make O=out ARCH=arm64 HOSTLDFLAGS="$HOSTLDFLAGS" vendor/msm8953-perf_defconfig vendor/mi8953.config 2>&1 | tee "$LOG_FILE"
fi

make -j"$(nproc --all)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang \
  HOSTLDFLAGS="$HOSTLDFLAGS" \
  CLANG_TRIPLE="$CLANG_PATH/aarch64-linux-gnu-" \
  CROSS_COMPILE="$GCC64_PATH/bin/aarch64-elf-" \
  CROSS_COMPILE_ARM32="$GCC32_PATH/bin/arm-eabi-" 2>&1 | tee -a "$LOG_FILE"

# Build sukses -> trap error tidak diperlukan lagi
trap - ERR

# Build sukses, log tidak diperlukan lagi
rm -f "$LOG_FILE"

# ===== Clone AnyKernel3 =====
echo "==> Packaging with AnyKernel3"
if [ -d "$KERNEL_DIR/AnyKernel" ]; then
  echo "AnyKernel folder already exists, updating..."
  rm -rf "$KERNEL_DIR/AnyKernel"
fi
git clone https://github.com/Ghnkz/Anykernel3 AnyKernel
cp out/arch/arm64/boot/Image.gz-dtb AnyKernel/

# ===== Zip kernel =====
cd AnyKernel
ZIP_NAME="NaughtyKernel${GIT_REF_NAME}-${BUILD_TIME}.zip"
zip -r "../${ZIP_NAME}" *
cd "$KERNEL_DIR"

echo "==> Done. Flashable zip is in $KERNEL_DIR/${ZIP_NAME}"

# ===== ☁️ Upload zip ke Gofile (tanpa login/token) =====
upload_to_gofile "$KERNEL_DIR/${ZIP_NAME}"

# ============================================================
# 🧹 Cleanup: hapus semua folder hasil curl / git clone
# (clang, gcc64, gcc32, KernelSU-Next, AnyKernel)
# ============================================================
echo "==> Membersihkan folder hasil curl/git clone (clang, gcc64, gcc32, KernelSU-Next, AnyKernel)..."
rm -rf "$KERNEL_DIR/clang" \
       "$KERNEL_DIR/gcc64" \
       "$KERNEL_DIR/gcc32" \
       "$KERNEL_DIR/KernelSU-Next" \
       "$KERNEL_DIR/AnyKernel"
rm -f "$KERNEL_DIR/.clang_bin_dir"

# Apakah folder "out" (hasil `make O=out`, BUKAN dari curl/git clone) juga
# mau ikut dihapus? Sama seperti pemilihan clang: bisa lewat variabel
# OUT_CHOICE (CI/non-interaktif) atau menu interaktif kalau tidak diset.
#   1) Simpan folder 'out'  -> build berikutnya incremental (lebih cepat)
#   2) Hapus folder 'out'   -> repo benar-benar bersih total, build
#                              berikutnya mulai dari nol lagi (lebih lambat)
select_out_cleanup() {
  if [ -z "${OUT_CHOICE:-}" ]; then
    if [ -t 0 ]; then
      echo "==> Folder 'out' mau diapakan?"
      select opt in "Simpan folder 'out' (incremental build)" "Hapus folder 'out' (bersih total)"; do
        case "$REPLY" in
          1|2) OUT_CHOICE="$REPLY"; break ;;
          *) echo "Pilihan tidak valid, coba lagi." ;;
        esac
      done
    else
      echo "==> Tidak ada input interaktif dan OUT_CHOICE tidak diset, default: simpan folder 'out'."
      OUT_CHOICE=1
    fi
  fi

  case "$OUT_CHOICE" in
    1)
      echo "==> Folder 'out' disimpan (build berikutnya incremental)."
      ;;
    2)
      echo "==> Menghapus folder 'out'..."
      rm -rf "$KERNEL_DIR/out"
      ;;
    *)
      echo "!! OUT_CHOICE='$OUT_CHOICE' tidak dikenal. Gunakan 1-2. Folder 'out' disimpan (default aman)."
      ;;
  esac
}
select_out_cleanup

# ============================================================
# ♻️ Kembalikan file yang sempat diedit oleh curl (setup.sh KernelSU-Next)
# ============================================================
if [ "$GIT_AVAILABLE" -eq 1 ]; then
  if [ -n "$MODIFIED_BY_SETUP" ]; then
    echo "==> Mengembalikan file tracked yang diedit oleh setup.sh KernelSU-Next:"
    echo "$MODIFIED_BY_SETUP"
    # shellcheck disable=SC2086
    git -C "$KERNEL_DIR" checkout -- $MODIFIED_BY_SETUP
  fi
  if [ -n "$NEW_FILES_BY_SETUP" ]; then
    echo "==> Menghapus file baru yang ditambahkan oleh setup.sh KernelSU-Next:"
    echo "$NEW_FILES_BY_SETUP"
    while IFS= read -r f; do
      [ -n "$f" ] && rm -rf "${KERNEL_DIR:?}/${f}"
    done <<< "$NEW_FILES_BY_SETUP"
  fi
  if [ -z "$MODIFIED_BY_SETUP" ] && [ -z "$NEW_FILES_BY_SETUP" ]; then
    echo "==> Tidak ada perubahan file tracked/baru yang perlu dikembalikan."
  fi
else
  echo "==> Dilewati: bukan repo git (atau git bermasalah), tidak ada yang bisa dikembalikan otomatis."
fi

echo "==> Selesai. Kernel tree sudah dibersihkan dari file toolchain/setup sementara."