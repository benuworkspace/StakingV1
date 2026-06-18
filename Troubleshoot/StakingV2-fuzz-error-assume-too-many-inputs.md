# Troubleshoot StakingV2: `forge test --match-test "Fuzz" --fuzz-runs 1000` error

## Gejala
Saat menjalankan fuzz test untuk `StakingV2`:

```bash
forge test --match-test "Fuzz" --fuzz-runs 1000 -vvv
```

Muncul error:

> `FAIL: vm.assume rejected too many inputs (65536 allowed)`

Fail terjadi pada fuzz test:
- `test_Fuzz_ProportionalReward(uint256,uint256)` di `test/StakingV2.t.sol`

## Akar masalah
Di fuzz test tersebut ada beberapa `vm.assume(...)` yang membatasi input fuzz (mis. range `aliceAmount`, `bobMultiplier`). Jika terlalu banyak kombinasi input yang ditolak oleh `vm.assume`, Foundry akan berhenti dengan error _“assume rejected too many inputs”_.

## Perbaikan yang dilakukan
File yang diubah:
- `test/StakingV2.t.sol`

Perubahan pada `test_Fuzz_ProportionalReward`:
1. Menghapus `vm.assume(...)` untuk pembatasan input fuzz pada `aliceAmount` dan `bobMultiplier`.
2. Mengganti dengan `bound(...)` agar input fuzz selalu dipetakan ke range yang valid secara deterministik.
3. Menambahkan `token.mint(...)` untuk memastikan balance token user mencukupi selama fuzz.

### Implementasi inti (ringkas)
Di dalam `test_Fuzz_ProportionalReward`:
- `aliceAmount = bound(aliceAmount, 1e18, 100_000 * 1e18);`
- `bobMultiplier = bound(bobMultiplier, 1, 10);`
- lalu `bobAmount = aliceAmount * bobMultiplier;`
- `token.mint(user1, aliceAmount);`
- `token.mint(user2, bobAmount);`

Dengan ini, fuzz tidak lagi membuang input terlalu banyak akibat `vm.assume`.

## Verifikasi
Setelah perbaikan, fuzz test berjalan sukses:

```bash
forge test --match-test "Fuzz" --fuzz-runs 1000 -vvv
```

Hasil:
- `StakingV1` fuzz: **PASS**
- `StakingV2` fuzz: **PASS** (0 failed)

## Catatan
- `vm.assume` tetap boleh dipakai untuk constraint yang tidak terlalu ketat.
- Untuk fuzz yang melibatkan banyak constraint, pola `bound(...)` biasanya lebih robust agar tidak memicu error batas penolakan input.

