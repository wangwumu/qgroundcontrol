#pragma once

#include <QFile>
#include <QMutex>
#include <QString>

#include <cstdint>

namespace MAVLinkCrypto {

/// 报文链路日志器（联调观察工具）。
///
/// 把 QGC 发出的和收到的 MAVLink 报文按时序写入固定路径文件（/tmp/qgc_crypto_link.log），
/// 供联调排查加密链路（QGC ↔ PX4 直连）。**仅在编译宏 `QGC_CRYPTO_LINK_LOG` 定义时启用**，
/// 正常构建零开销（方法体为空）。
///
/// 日志格式（空格分隔，字段对齐，每报文一行）：
/// ```
/// 序号(5位右) 时间(HH:MM:SS) 发送端(QGC/PX4) C/A mavlink命令 deviceID(6位右) M/C S/F 说明(20汉字) payload长度(3位右) 内容
/// ```
/// - C/A：命令触发（C，COMMAND/MISSION/80000-80003 等）/ 自动发送（A，心跳/登记心跳/遥测）
/// - M/C：明文 / 密文
/// - S/F：解析成功 / 失败（加密帧=解密认证结果）
///
/// 报文内容按消息类型解析为可读文本：80005 的 payload 解析为 deviceID 集合
/// （"001111,001112"），加密帧解析 counter 等。
class CryptoLinkLogger
{
public:
    /// 单例（首次调用时创建，进程生命周期内有效）。
    static CryptoLinkLogger* instance();
    /// 日志是否启用（联调宏 QGC_CRYPTO_LINK_LOG 控制，供调用方/测试运行时判断）。
    static bool enabled();

    /// 记录一个 QGC 发出的报文（bytes/len 为完整帧字节）。
    /// @param plainBytes/plainLen 明文帧字节：加密帧=加密前的原始标准帧；明文帧=可传 null
    ///        （bytes 本身即明文）。日志内容会解析出可读字段（如 GLOBAL_POSITION_INT 的坐标）。
    /// @param parseOk 发送侧解析状态：加密帧=加密是否成功，明文=恒 true
    /// @param failReason parseOk=false 时写入报文内容的失败原因
    void logOutgoing(uint32_t msgid, uint32_t deviceID, bool encrypted, const char* bytes, int len,
                     const char* plainBytes, int plainLen, bool parseOk,
                     const QString& failReason = QString());
    /// 记录一个收到的（PX4 发出）报文。
    /// @param plainBytes/plainLen 明文帧字节：加密帧=解密后的标准帧；明文帧=可传 null
    /// @param parseOk 接收侧解析状态：加密帧=解密认证是否成功，明文=恒 true
    /// @param failReason parseOk=false 时写入报文内容的失败原因
    void logIncoming(uint32_t msgid, uint32_t deviceID, bool encrypted, const char* bytes, int len,
                     const char* plainBytes, int plainLen, bool parseOk,
                     const QString& failReason = QString());

    /// 命令类消息判定（用户命令触发 vs 自动发送）。
    static bool isCommandMessage(uint32_t msgid);
    /// 80005 登记心跳 payload → deviceID 集合文本（"001111,001112"）。
    static QString parseRegistrationPayload(const char* bytes, int len);
    /// 从帧字节重组帧头 deviceID（§1.2：incompat<<24|compat<<16|sys<<8|comp）。
    static uint32_t deviceIDFromFrameBytes(const char* bytes, int len);

private:
    explicit CryptoLinkLogger();
    ~CryptoLinkLogger();

    void _append(bool outgoing, bool encrypted, bool parseOk, uint32_t msgid, uint32_t deviceID,
                 const QString& note, int payloadLen, const QString& content,
                 const QString& failReason = QString());
    /// 说明文本（20 汉字内，描述报文用途）。
    static QString _describeMsgid(uint32_t msgid);
    /// 报文内容解析（按 msgid + 明文/密文 + 明文帧）。
    static QString _parseContent(uint32_t msgid, bool encrypted, const char* bytes, int len,
                                 const char* plainBytes, int plainLen);
    /// 标准帧字节 → 可读字段文本（按 msgid 解析关键字段）。
    static QString _parsePlainFields(uint32_t msgid, const char* plainBytes, int plainLen);
    /// 标准帧字节 → mavlink_message_t（手动解析，无需 mavlink channel）。
    static void _frameToMessage(const char* bytes, int len, mavlink_message_t& msg);

    /// 按 CJK 宽度填充到指定显示列宽（不足右补空格）。
    static QString _padToWidth(const QString& s, int width);
    /// 左补空格到指定宽度（右对齐）。
    static QString _padLeft(const QString& s, int width);

    QFile _file;
    QMutex _mutex;
    quint64 _seq = 0;
};

} // namespace MAVLinkCrypto
