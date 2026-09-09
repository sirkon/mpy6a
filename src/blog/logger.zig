const std = @import("std");
const encoder = @import("encoder.zig"); // Твой файл со схлопнутыми append/appendVarint

const LogLevel = enum(u8) { trace = 10, debug = 20, info = 30, warning = 40, err = 50, panic = 60 };
const Version: u16 = 1;

// Имитируем твою структуру LogContext, которая уже содержит сериализованные байты
pub const LogContext = struct {
    bytes: []u8,
    len: usize, // Текущая длина записанных данных контекста
};

pub const Logger = struct {
    const Self = @this();

    // В реальной mpy6a здесь будет ссылка на твое локальное кольцо треда ядра CPU
    ring_buffer: *YourRingBuffer,

    pub fn warn(self: *Self, msg: []const u8, ctx: anytype) !void {
        const CtxType = @TypeOf(ctx);

        // Переменная для хранения итоговой длины всего WAL-пакета
        var total_size: usize = 0;

        // 1. Базовый заголовок WAL: version(2) + time(8) + level(1) + loc_stub(1)
        total_size += 2 + 8 + 1 + 1;

        // 2. Добавляем размер самого сообщения: varint(msg.len) + msg.len
        total_size += sizeOfUvarint(msg.len) + msg.len;

        // ----------------------------------------------------------------
        // КОМПТАЙМ-ВЕТВЛЕНИЕ: Анализируем тип контекста
        // ----------------------------------------------------------------
        if (comptime CtxType == *LogContext) {
            // Ветка А: Прилетел готовый контекст, длина уже известна в рантайме!
            total_size += ctx.len;
        }

        if (comptime CtxType != *LogContext and @activeTag(@typeInfo(CtxType)) == .@"struct") {
            // Ветка Б: Прилетела анонимная структура. Генерируем формулу длины в comptime
            inline for (@typeInfo(CtxType).@"struct".fields) |field| {
                // Размер имени поля (ключа): varint(key.len) + key.len
                total_size += comptime (sizeOfUvarint(field.name.len) + field.name.len);

                // Размер значения поля
                const FType = field.type;
                switch (@typeInfo(FType)) {
                    .bool => total_size += 1,
                    .int => |info| {
                        if (info.bits == 8) total_size += 1 else total_size += info.bits / 8;
                    },
                    .float => |info| total_size += info.bits / 8,
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .Slice and ptr_info.child == u8) {
                            // Для строк в анонимной структуре: varint(len) + len
                            const str_val = @field(ctx, field.name);
                            total_size += sizeOfUvarint(str_val.len) + str_val.len;
                        } else {
                            @compileError("Пока поддерживаем только строки []const u8 в структуре");
                        }
                    },
                    else => @compileError("Неподдерживаемый тип поля: " ++ @typeName(FType)),
                }
            }
        } else {
            @compileError("warn() ожидает либо *blog.LogContext, либо анонимную структуру, получил " ++ @typeName(CtxType));
        }

        // ----------------------------------------------------------------
        // ВЫДЕЛЕНИЕ ПАМЯТИ: Запрашиваем ровно total_size байт у кольца
        // ----------------------------------------------------------------
        var slice = try self.ring_buffer.getSlice(total_size);
        var ptr: [*]u8 = slice.ptr;

        // ----------------------------------------------------------------
        // СЕРИАЛИЗАЦИЯ ПО ЦЕПОЧКЕ СДВИГА УКАЗАТЕЛЯ
        // ----------------------------------------------------------------
        ptr = encoder.append(ptr, Version);
        ptr = encoder.append(ptr, @as(u64, @intCast(std.time.nanoTimestamp())));
        ptr = encoder.append(ptr, @intFromEnum(LogLevel.warning));
        ptr = encoder.append(ptr, @as(u8, 0)); // локация-заглушка

        // Пишем сообщение
        ptr = encoder.appendVarint(ptr, msg.len);
        ptr = encoder.append(ptr, msg);

        // Записываем сам контекст
        if (comptime CtxType == *LogContext) {
            // Ветка А: Просто копируем готовый сериализованный кусок памяти контекста одним махом
            @memcpy(ptr[0..ctx.len], ctx.bytes[0..ctx.len]);
            ptr += ctx.len;
        } else {
            // Ветка Б: Раскладываем анонимную структуру по вычисленной цепочке
            inline for (@typeInfo(CtxType).@"struct".fields) |field| {
                const val = @field(ctx, field.name);

                // Пишем ключ
                ptr = encoder.appendVarint(ptr, field.name.len);
                ptr = encoder.append(ptr, field.name);

                // Пишем значение
                if (comptime field.type == []const u8 or field.type == []u8) {
                    ptr = encoder.appendVarint(ptr, val.len);
                    ptr = encoder.append(ptr, val);
                } else {
                    ptr = encoder.append(ptr, val); // Примитивы улетают по MOV
                }
            }
        }

        // Проверяем инвариант безопасности: записано тютелька в тютельку
        std.debug.assert(ptr - slice.ptr == total_size);
    }
};

// Быстрый рантайм-подсчет размера Uvarint через LZCNT
pub inline fn sizeOfUvarint(value: u64) usize {
    if (value == 0) return 1;
    const bits = 64 - @clz(value);
    return (bits + 6) / 7;
}
