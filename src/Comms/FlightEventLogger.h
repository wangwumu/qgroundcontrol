#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QDateTime>
#include <QtCore/QFile>
#include <QtCore/QHash>
#include <QtCore/QMutex>
#include <QtCore/QString>

// 前向声明 mavlink_message_t（QGC 经 mavlink_types.h 定义，避免本头依赖 PCH 注入）
typedef struct __mavlink_message mavlink_message_t;

/// 飞行事件日志：把 QGC 与飞控之间的命令、应答、动作、状态、异常、链路事件，
/// 以及 QGC 侧的界面/流程事件，按时序写入一个按启动时刻命名的文本文件。
///
/// 与 `/tmp/FlightDataXXXXXX.mavlink` 的分工：
/// - 那个文件是**全量原始帧**，且**发送方向写的是加密后的字节**（见 MAVLinkProtocol::logSentBytes），
///   事后无法直接读出「我发了什么命令」；
/// - 本文件只记**关键事件**，且发送方向取自加密之前的明文，用于排查
///   「发了什么命令 / 飞控怎么应答 / 报了什么警」。
///
/// 文件路径：`<AppDataLocation>/FlightLogs/qgc_flight_YYYYMMDD_HHMMSS.log`
/// 每行格式：`<本地时间 ISO 含毫秒与偏移> | <方向> | <类别> | <正文> | <备注>`
/// 文件头部若干 `#` 开头的注释行说明格式，解析时按前缀过滤即可。
///
/// 线程：写盘路径全部持 _mutex。发送侧钩子（LinkInterface::sendMessageThreadSafe）
/// 可能被非主线程调用，因此不能假定单线程。
class FlightEventLogger
{
public:
    /// 事件方向。由调用点决定，不从帧内容猜（同一 msgid 两个方向都可能出现）。
    enum class Direction {
        ToVehicle,    ///< QGC → 飞控
        FromVehicle,  ///< 飞控 → QGC
        Local,        ///< QGC 内部：界面、流程、守卫
    };

    /// 事件类别。None 表示该帧不属本日志的关注范围，不写盘。
    enum class Category {
        None,
        Command,   ///< 命令：QGC 发出的指令
        Ack,       ///< 应答：飞控对命令的回应
        Action,    ///< 动作：目标点变化、航点到达、起降与转换状态
        Status,    ///< 状态：解锁、飞行模式、传感器健康
        Alert,     ///< 异常：飞控状态文本 / 报警
        Link,      ///< 链路：心跳中断与恢复、版本握手、航线上传与参数下载
        Ui,        ///< 界面：按钮被拒、流程中止、守卫拦截
    };

    /// 高频「状态流」：同一个流的重复播报按**取值**去重。
    ///
    /// None 表示该报文是**事件**不是状态 —— 一律逐条记录。
    /// 报警尤其不能进这个集合：飞控出问题时正是靠反复播报暴露的，
    /// 把重复的 STATUSTEXT 去重掉，等于把最该看的那几行删掉。
    enum class Stream {
        None,
        HeartbeatState,    ///< 心跳里的解锁位 / 自定义模式 / 系统状态
        SysStatusHealth,   ///< SYS_STATUS 的传感器健康位图与电池
        TargetPoint,       ///< 当前目标点
    };

    static FlightEventLogger* instance();

    // ------------------------------------------------------------------
    // 纯函数：不碰文件、不读时钟、不依赖单例状态，可直接单测
    // ------------------------------------------------------------------

    /// 判断一帧属于哪一类；不属本日志范围时返回 Category::None。
    static Category classify(const mavlink_message_t& message);

    /// 把一帧渲染成日志正文；不属本日志范围时返回空串。
    /// 方向不参与正文 —— 它是 formatLine 的一列，由调用点（收/发钩子）决定。
    static QString renderFrame(const mavlink_message_t& message);

    /// 判断一帧属于哪个高频状态流；事件类报文返回 Stream::None。
    static Stream streamOf(const mavlink_message_t& message);

    /// 类别 → 中文列名（日志里与界面上都不出现裸枚举）。
    static QString categoryLabel(Category category);

    /// 方向 → 列名。
    static QString directionLabel(Direction direction);

    /// 拼一整行；note 为空时不追加该列。
    static QString formatLine(const QDateTime& when, Direction direction, Category category,
                              const QString& body, const QString& note = QString());

    /// 日志文件名。按启动时刻命名。
    static QString fileNameFor(const QDateTime& when);

    /// 在 dir 下取一个不与既有文件重名的日志文件名（同秒二次启动追加 -2、-3…）。
    /// 全部被占用时返回空串 —— 由调用方判失败，**不静默覆盖**既有日志。
    static QString uniqueFileNameIn(const QString& dir, const QDateTime& when);

    // ------------------------------------------------------------------
    // 高频去重：判定是纯函数，状态由调用方（单例）持有
    // ------------------------------------------------------------------

    struct StreamState {
        bool       hasValue = false;
        QByteArray value;
        QDateTime  lastWrittenAt;
    };

    struct StreamDecision {
        bool   write = false;
        double secondsSinceLastWrite = -1.0;  ///< 距上次**写入**的秒数；<0 表示此前没写过
    };

    /// 取值未变则不写；写入时返回距上次写入的秒数，供「这个状态稳定了多久」的判断。
    static StreamDecision decideStreamWrite(StreamState& state, const QByteArray& value,
                                            const QDateTime& now);

    // ------------------------------------------------------------------
    // 心跳间隔监测
    // ------------------------------------------------------------------

    /// PX4 心跳约 1 Hz；5 秒无声已是异常，不是抖动。
    static constexpr double kHeartbeatGapThresholdSeconds = 5.0;

    struct HeartbeatGap {
        bool   resumed = false;      ///< 本次心跳标志着一段静默之后恢复
        double silentSeconds = 0.0;  ///< 静默时长；首次心跳（无上次）为 0
    };

    /// lastHeartbeatAt 由调用方跨调用保存；首次调用返回 resumed=false。
    static HeartbeatGap observeHeartbeat(QDateTime& lastHeartbeatAt, const QDateTime& now,
                                         double thresholdSeconds = kHeartbeatGapThresholdSeconds);

    // ------------------------------------------------------------------
    // 文件生命周期
    // ------------------------------------------------------------------

    /// 打开日志文件。directory 为空时用 `<AppDataLocation>/FlightLogs`。
    /// 已打开的文件先关闭。返回 false 表示打不开（路径建不出 / 文件无法写）——
    /// 调用方负责把这件事报出去，本类不静默吞。
    bool start(const QString& directory = QString());

    void stop();
    bool isOpen() const;
    QString filePath() const;

    // ------------------------------------------------------------------
    // 写入
    // ------------------------------------------------------------------

    /// 记录一帧；返回是否真的写了一行（不属范围 / 状态未变时为 false）。
    ///
    /// 收到的**每一帧**心跳都会参与中断判定，与该帧最终是否写盘无关 ——
    /// 否则一条取值未变的心跳被跳过后，「心跳中断」将永远不会被观测到。
    ///
    /// 未 start() 时全部丢弃（钩子可能先于 start 接线）；这不报错，但也不缓冲。
    bool logFrame(Direction direction, const mavlink_message_t& message,
                  const QDateTime& now = QDateTime::currentDateTime());

    /// 记录一条 QGC 侧事件（按钮被拒、流程中止、守卫拦截）。
    void logLocalEvent(const QString& text,
                       const QDateTime& now = QDateTime::currentDateTime());

    /// 记录一条链路层事件（心跳中断与恢复、版本握手、航线上传）。
    void logLinkEvent(const QString& text,
                      const QDateTime& now = QDateTime::currentDateTime());

private:
    FlightEventLogger() = default;

    /// 写一行并落盘；返回是否写了。调用方须已持有 _mutex。
    bool _writeLineLocked(const QString& line);

    mutable QMutex _mutex;
    QFile          _file;
    /// 键＝方向 << 32 | msgid。**方向必须进键**：同一条报文两个方向都有（心跳最典型），
    /// 只按 msgid 存会让两条流互相顶掉对方的取值 ⇒ 去重失效、每条都当「变了」写出去。
    QHash<uint64_t, StreamState> _streams;
    QDateTime      _lastHeartbeatAt;
};
