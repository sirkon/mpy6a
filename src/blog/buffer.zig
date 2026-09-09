const std = @import("std");

/// Принимает сырой указатель `dst`, укладывает значение `v` и возвращает сдвинутый указатель.
pub inline fn append(dst: [*]u8, v: anytype) [*]u8 {
    const T = @TypeOf(v);
    var ptr = dst;

    switch (@typeInfo(T)) {
        .bool => {
            ptr[0] = @intFromBool(v);
            return ptr + 1;
        },
        .int => |info| {
            comptime std.debug.assert(info.bits <= 64);
            if (info.bits == 8) {
                ptr[0] = @bitCast(v);
                return ptr + 1;
            } else {
                const size = info.bits / 8;
                const le_val = std.mem.nativeTo(T, v, .little);
                @memcpy(ptr[0..size], std.mem.asBytes(&le_val));
                return ptr + size;
            }
        },
        .float => |info| {
            const size = info.bits / 8;
            if (info.bits == 32) {
                const u_val: u32 = @bitCast(v);
                @memcpy(ptr[0..4], std.mem.asBytes(&u_val));
            } else {
                const u_val: u64 = @bitCast(v);
                @memcpy(ptr[0..8], std.mem.asBytes(&u_val));
            }
            return ptr + size;
        },
        .pointer => |ptr_info| {
            // Обрабатываем только слайсы (динамические массивы)
            if (ptr_info.size == .slice) {
                const Child = ptr_info.child;

                // Проверяем, что тип элемента тривиальный и поддерживаемый
                if (comptime !isTrivialSupportedType(Child)) {
                    @compileError("Слайсы типа " ++ @typeName(Child) ++ " не поддерживаются в append.");
                }

                // ОПТИМИЗАЦИЯ: если это слайс байт (u8 или i8), копируем всё одним махом
                if (Child == u8 or Child == i8) {
                    @memcpy(ptr[0..v.len], std.mem.sliceAsBytes(v));
                    return ptr + v.len;
                } else {
                    // ИНАЧЕ: Разворачиваем в плоский сериализатор на этапе компиляции.
                    // Цикл исчезнет, останутся только последовательные записи элементов в память.
                    for (v) |item| {
                        ptr = append(ptr, item);
                    }
                    return ptr;
                }
            }

            // Поддержка строковых литералов (*const [N]u8)
            if (ptr_info.size == .One and @typeInfo(ptr_info.child) == .Array and ptr_info.child.Array.child == u8) {
                const slice: []const u8 = v;
                @memcpy(ptr[0..slice.len], slice);
                return ptr + slice.len;
            }

            @compileError("Неподдерживаемый тип указателя в append: " ++ @typeName(T));
        },
        else => @compileError("Неподдерживаемый тип для append: " ++ @typeName(T)),
    }
}

/// Схлопнутая функция для varint.
/// Сама разберется: если тип signed — сделает Зигзаг, если unsigned — бахнет Uleb128.
pub inline fn appendVarint(dst: [*]u8, v: anytype) [*]u8 {
    const T = @TypeOf(v);
    const info = @typeInfo(T);

    // Проверяем, что нам вообще подсунули целое число
    if (info != .int) {
        @compileError("appendVarint works with integer types only, got " ++ @typeName(T));
    }

    var ptr = dst;
    var val: u64 = undefined;

    // Магия компилятора: ветвление исчезнет в бинарнике, останется только нужная математика
    if (info.Int.signedness == .signed) {
        // Зигзаг для знакомых (i8, i16, i32, i64)
        const bits = info.Int.bits;
        const casted = @as(u64, @bitCast(@as(i64, v)));
        val = (casted << 1) ^ @as(u64, @bitCast(@as(i64, v) >> (bits - 1)));
    } else {
        // Прямой каст в u64 для беззнаковых (u8, u16, u32, u64, usize)
        val = @as(u64, v);
    }

    // Общий цикл укладки LEB128 байт в память по указателю
    while (val >= 0x80) {
        ptr[0] = @as(u8, @truncate(val)) | 0x80;
        ptr += 1;
        val >>= 7;
    }
    ptr[0] = @as(u8, @truncate(val));
    return ptr + 1;
}

/// Наша comptime-проверка на тривиальный тип
fn isTrivialSupportedType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .bool, .int, .float => return true,
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) return true;
            if (ptr_info.size == .one) {
                switch (@typeInfo(ptr_info.child)) {
                    .Array => |arr_info| return arr_info.child == u8,
                    else => return false,
                }
            }
            return false;
        },
        else => return false,
    }
}
