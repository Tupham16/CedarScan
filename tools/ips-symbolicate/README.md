# Đọc crash log `.ips` bằng dSYM — TRÊN WINDOWS, không cần Mac

🔴 **Handoff từng ghi "symbolicate từ Windows là BẤT KHẢ, phải có máy Mac chạy `atos`". Câu đó
SAI KỂ TỪ KHI CÓ dSYM.** Cái bất khả hồi đó là symbolicate bằng **binary Release trong IPA** (đã
strip, symtab chỉ còn `__mh_execute_header`). dSYM thì mang đủ `__debug_line` + symtab, và DWARF
là định dạng mở — đọc bằng Python được, không cần công cụ Apple.

Bộ script này đã giải xong vụ văng 11/08 (§CRASH ĐANG MỞ). Giữ lại để lần sau khỏi phải dựng lại.

## Dùng

```bash
python tools/ips-symbolicate/symbolicate.py <dSYM>/Contents/Resources/DWARF/CedarScan <file.ips>
```

Nó tự: đọc `slice_uuid` + `app_version` ở dòng đầu `.ips`, đối chiếu `LC_UUID` của dSYM (in ra
`UUID MATCH: True/False` — **sai thì DỪNG, mọi số phía sau là rác**), rồi in mọi khung thuộc
image `CedarScan` của luồng bị trigger kèm tên hàm + `file:dòng:cột`.

Chọn dSYM theo `app_version` trong `.ips` → thư mục `dsym-<version>/` ở gốc repo.

### Khi muốn soi kỹ một khung

```bash
python tools/ips-symbolicate/rangedump.py <DWARF/CedarScan> <imageOffset> [<imageOffset> …]
```

In TOÀN BỘ bảng dòng của hàm chứa địa chỉ đó. Cần nó vì hai lẽ:

- **PC trong khung ≠ chỗ gây lỗi.** Khung không phải khung 0 giữ ĐỊA CHỈ TRẢ VỀ. Với lời gọi
  `noreturn` (`EnvironmentObject.error()`, `fatalError`) thì địa chỉ trả về rơi đúng CUỐI hàm và
  dòng ở đó là `<compiler-generated>` — vô dụng. Dòng thật nằm ở hàng ngay TRƯỚC nó.
- **Swift đẩy nhánh lạnh xuống đuôi hàm.** Nhánh "environment không có object" của
  `@EnvironmentObject` nằm SAU lệnh return của đường bình thường, nhưng mang ĐÚNG số dòng/cột của
  chỗ đọc. Thấy cùng một `file:dòng:cột` xuất hiện HAI LẦN — một lần đầu hàm, một lần sau return —
  thì lần thứ hai chính là nhánh chết.

## Số học phải nhớ

- Địa chỉ tra cứu = `0x100000000 + imageOffset`. `0x100000000` là `vmaddr` của segment `__TEXT`
  trong dSYM (script tự kiểm, đừng sửa mò).
- `imageOffset` trong `.ips` đã là offset so với đầu image rồi — ✗ cộng thêm `base` của
  `usedImages`.
- Chỉ đọc khung có `imageIndex` trỏ vào image tên `CedarScan`; khung hệ thống thì `.ips` đã ghi
  sẵn tên hàm.

## File

| File | Việc |
|---|---|
| `macho.py` | đọc Mach-O: `LC_UUID`, section `__DWARF`, `LC_SYMTAB` |
| `dwarfline.py` | chạy máy trạng thái `__debug_line` (DWARF 2–5) → bảng (địa chỉ → file:dòng:cột); + tra symtab |
| `symbolicate.py` | kiểm UUID + in các khung CedarScan của luồng trigger |
| `rangedump.py` | đổ toàn bộ bảng dòng của một hàm |

Không phụ thuộc gói ngoài — chỉ thư viện chuẩn Python 3.
