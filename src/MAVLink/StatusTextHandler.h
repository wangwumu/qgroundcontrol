#pragma once

#include <QtCore/QDateTime>
#include <QtCore/QList>
#include <QtCore/QObject>
#include <QtCore/QVariantList>

#include "MAVLinkEnums.h"
#include "MAVLinkMessageType.h"

class StatusTextHandler;
class QTimer;

class StatusText
{
public:
    StatusText(MAV_COMPONENT componentid, MAV_SEVERITY severity, const QString &text);

    bool severityIsError() const;

    MAV_COMPONENT getComponentID() const { return m_compId; }
    MAV_SEVERITY getSeverity() const { return m_severity; }
    QString getText() const { return m_text; }
    QString getFormattedText() const { return m_formatedText; }

    /// 本条消息**到达地面站**的时刻（UTC）。
    /// ‼️ 在构造时盖，**不是**在 QML 侧盖（设计文档 §6.1）：QML 只有在首次拉取历史时
    ///    才接触旧消息，那时盖的时间是"现在" ⇒ 整屏历史告警会显示成同一秒，
    ///    而"告警什么时候发生的"恰恰是这类列表里最有用的信息。
    /// ⚠️ 与 `getFormattedText()` 里那个 `hh:mm:ss.zzz` **不是**同一个时间：那个是
    ///    **本地时间**、只进 HTML 串、不对外暴露（`MainStatusIndicator` 那类渲染吃它）。
    ///    本字段是 UTC、供 QML 显示与排序。刻意不合并——改 `formattedText` 会动到
    ///    既有 `VehicleMessageList.qml` 的渲染。
    QDateTime getTimestamp() const { return m_timestamp; }

    void setFormatedText(const QString &formatedText) { m_formatedText = formatedText; }

private:
    MAV_COMPONENT m_compId;
    MAV_SEVERITY m_severity;
    QString m_text;
    QString m_formatedText;
    // ⚠️ 声明在最后：构造函数的初始化列表按**声明顺序**执行，顺序不一致时
    //    `-Wreorder` 会报警（本仓按 -Werror 构建）。
    QDateTime m_timestamp;
};

class StatusTextHandler : public QObject
{
    Q_OBJECT

    enum class MessageType {
        MessageNone,
        MessageNormal,
        MessageWarning,
        MessageError
    };

public:
    explicit StatusTextHandler(QObject *parent = nullptr);
    ~StatusTextHandler();

    void mavlinkMessageReceived(const mavlink_message_t &message);
    void handleHTMLEscapedTextMessage(MAV_COMPONENT componentid, MAV_SEVERITY severity, const QString &text, const QString &description);

    void clearMessages();
    void resetAllMessages();
    void resetErrorLevelMessages();

    const QList<StatusText*>& messages() const { return m_messages; }
    QString formattedMessages() const;

    /// `messages()` 的 **QML 可见形态**：`[{componentid, severity, text, timestamp}, ...]`
    /// （设计文档 §6.1 路 B）。
    /// ‼️ **必须转成 `QVariantList`**：`StatusText` 既不是 `QObject` 也不是 `Q_GADGET`，
    ///    QML 读不了它的任何成员 ⇒ 把 `messages()` 直接暴露出去只会得到一堆不可读的指针。
    /// ⚠️ 这里**刻意没有**配套的 `Q_PROPERTY`：QML 侧的消费者是 `Vehicle::statusTextMessages`，
    ///    而 `Vehicle` 只**前向声明**了本类（`Vehicle.h:62`）。让 `Vehicle` 转发数据、
    ///    而不是转发裸指针，QML 那边就一个字都不需要认识本类型，也不必让 `Vehicle.h`
    ///    去 include 本头文件。
    /// 顺序与 `messages()` 一致（**旧的在前**）——`StatusTextHandler` 是 append，
    /// 取"最近 N 条"是取**尾部**。
    QVariantList messagesVariant() const;

    bool messageTypeNone() const { return (m_messageType == MessageType::MessageNone); }
    bool messageTypeNormal() const { return (m_messageType == MessageType::MessageNormal); }
    bool messageTypeWarning() const { return (m_messageType == MessageType::MessageWarning); }
    bool messageTypeError() const { return (m_messageType == MessageType::MessageError); }

    uint32_t getErrorCount() const { return m_errorCount; }
    uint32_t getErrorCountTotal() const { return m_errorCountTotal; }
    uint32_t getWarningCount() const { return m_warningCount; }
    uint32_t getNormalCount() const { return m_normalCount; }
    uint32_t messageCount() const { return m_messageCount; }

    static QString getMessageText(const mavlink_message_t &message);

signals:
    void newFormattedMessage(QString message);
    void textMessageReceived(MAV_COMPONENT componentid, MAV_SEVERITY severity, QString text, QString description);
    void messageCountChanged(uint32_t newCount);
    void messageTypeChanged();
    void newErrorMessage(QString message);

    /// `m_messages` 的**内容**变了：新增一条，或被 `clearMessages()` 清空。
    /// ‼️ **刻意不覆盖** `resetAllMessages()` / `resetErrorLevelMessages()`：那两个只重置
    ///    **计数**、一个字都不动 `m_messages`（它们是"标记已读"语义，服务
    ///    `MainStatusIndicator` 那类只关心有没有新错误的指示器）。告警列表是机载事实的
    ///    账本，不随"已读"增减——这与本列表**不设"清空"按钮**是同一个理由（§6.3）。
    void messagesChanged();

private slots:
    void _chunkedStatusTextTimeout();

private:
    void _handleStatusText(const mavlink_message_t &message);
    void _handleTextMessage(uint32_t newCount, MessageType messageType = MessageType::MessageNone);
    void _chunkedStatusTextCompleted(MAV_COMPONENT compId);

    QTimer *m_chunkedStatusTextTimer = nullptr;

    bool m_multiComp = false;
    MAV_COMPONENT m_activeComponent = MAV_COMPONENT::MAV_COMPONENT_ENUM_END;
    uint32_t m_errorCount = 0;
    uint32_t m_errorCountTotal = 0;
    uint32_t m_warningCount = 0;
    uint32_t m_normalCount = 0;
    uint32_t m_messageCount = 0;

    QVector<StatusText*> m_messages;

    MessageType m_messageType = MessageType::MessageNone;

    typedef struct __ChunkedStatusTextInfo {
        uint16_t chunkId;
        MAV_SEVERITY severity;
        QStringList rgMessageChunks;
    } ChunkedStatusTextInfo_t;

    QMap<MAV_COMPONENT, ChunkedStatusTextInfo_t> m_chunkedStatusTextInfoMap;
};
