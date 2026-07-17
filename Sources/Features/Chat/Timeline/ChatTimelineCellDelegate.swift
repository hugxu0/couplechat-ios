import UIKit

protocol ChatTimelineCellDelegate: AnyObject {
    func chatCellDidTapMedia(_ cell: ChatNativeMessageCell)
    func chatCellDidTapLink(_ cell: ChatNativeMessageCell, url: URL)
    func chatCellDidTapRetry(_ cell: ChatNativeMessageCell)
    func chatCellDidTapTranscript(_ cell: ChatNativeMessageCell)
    func chatCellDidTapReply(_ cell: ChatNativeMessageCell)
    func chatCellDidDecideConfirm(_ cell: ChatNativeMessageCell, decision: String)
    func chatCellDidResolveMediaLayout(_ cell: ChatNativeMessageCell, mediaSize: CGSize)
}
