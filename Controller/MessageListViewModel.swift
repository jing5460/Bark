//
//  MessageListViewModel.swift
//  Bark
//
//  Created by huangfeng on 2020/11/21.
//  Copyright © 2020 Fin. All rights reserved.
//

import Foundation
import RealmSwift
import RxCocoa
import RxDataSources
import RxSwift

enum MessageListType: Int, Codable {
    // 列表
    case list
    // 分组
    case group
}

enum MessageSourceType {
    /// 全部数据源
    case all
    /// 只查看某一个分组
    case group(String?)
}

class MessageListViewModel: ViewModel, ViewModelType {
    struct Input {
        /// 刷新
        var refresh: Driver<Void>
        /// 加载更多
        var loadMore: Driver<Void>
        /// 删除
        var itemDelete: Driver<MessageListCellItem>
        /// 点击
        var itemSelected: Driver<Int>
        /// 批量删除
        var delete: Driver<MessageDeleteType>
        /// 切换群组和列表显示样式
        var groupToggleTap: Driver<Void>
        /// 搜索
        var searchText: Observable<String?>
    }
    
    struct Output {
        /// 数据源
        var messages: Driver<[MessageSection]>
        /// 刷新控件状态
        var refreshAction: Driver<MJRefreshAction>
        /// 点击后，弹出提示
        var alertMessage: Driver<(String, Int)>
        /// 群组过滤
        var type: Driver<MessageListType>
        /// 标题
        var title: Driver<String>
        /// 群组切换按钮是否隐藏
        var groupToggleButtonHidden: Driver<Bool>
    }

    private static let typeKey = "me.fin.messageListType"
    /// 当前显示类型
    private var type: MessageListType = {
        if let t: MessageListType = Settings[MessageListViewModel.typeKey] {
            return t
        }
        return .list
    }() {
        didSet {
            Settings[MessageListViewModel.typeKey] = type
        }
    }
    
    /// 数据源
    private var sourceType: MessageSourceType = .all
    
    /// 当前页数
    private var page = 0
    /// 每页数量
    private let pageCount = 20
    
    /// 全部群组
    private var groups: Results<Message>?
    /// 全部数据（懒加载）
    private var results: Results<Message>?
    
    convenience init(sourceType: MessageSourceType) {
        self.init()
        self.sourceType = sourceType
    }
    
    /// 获取筛选后的全部数据源 （懒加载）
    private func getResults(filterGroups: [String?], searchText: String?) -> Results<Message>? {
        if let realm = try? Realm() {
            var results = realm.objects(Message.self)
                .sorted(byKeyPath: "createDate", ascending: false)
            if filterGroups.count > 0 {
                results = results.filter("group in %@", filterGroups)
            }
            if let text = searchText, text.count > 0 {
                results = results.filter("title CONTAINS[c] %@ OR subtitle CONTAINS[c] %@ OR body CONTAINS[c] %@", text, text, text)
            }
            return results
        }
        return nil
    }
    
    /// 当前正在搜索的文字
    private var searchText: String = ""
    
    /// 获取所有群组（懒加载）
    private func getGroups() -> Results<Message>? {
        if let realm = try? Realm() {
            return realm.objects(Message.self)
                .sorted(byKeyPath: "createDate", ascending: false)
                .distinct(by: ["group"])
//                .value(forKeyPath: "group") as? [String?] ?? []
        }
        return nil
    }

    /// 获取 message 列表下一页数据
    private func getListNextPage() -> [MessageListCellItem] {
        guard let result = results else {
            return []
        }
        let startIndex = page * pageCount
        let endIndex = min(startIndex + pageCount, result.count)
        guard endIndex > startIndex else {
            return []
        }
        var messages: [MessageListCellItem] = []
        for i in startIndex..<endIndex {
            // messages.append(result[i].freeze())
            // 不用 freeze 是还没弄明白 freeze 冻结快照释放时机，先直接copy吧
            // copy 是因为 message 可能在被删除后，还会被访问导致闪退
            messages.append(.message(model: MessageItemModel(message: result[i])))
        }
        page += 1
        return messages
    }

    /// 获取 group 列表下一页数据
    private func getGroupNextPage() -> [MessageListCellItem] {
        guard let groups, let results else {
            return []
        }
        
        let startIndex = page * pageCount
        let endIndex = min(startIndex + pageCount, groups.count)
        guard endIndex > startIndex else {
            return []
        }

        var items: [MessageListCellItem] = []
        
        for i in startIndex..<endIndex {
            let group = groups[i].group
            let messageResult: Results<Message>
            if let group {
                messageResult = results.filter("group == %@", group)
            } else {
                messageResult = results.filter("group == nil")
            }
                
            var messages: [MessageItemModel] = []
            for i in 0..<min(messageResult.count, 5) {
                messages.append(MessageItemModel(message: messageResult[i]))
            }
            if messages.count > 0 {
                items.append(.messageGroup(name: group ?? NSLocalizedString("default"), totalCount: messageResult.count, messages: messages))
            }
        }
        page += 1
        return items
    }
    
    private func getNextPage() -> [MessageListCellItem] {
        if case .group = self.sourceType {
            // 查看指定分组时，只能按列表查看
            return getListNextPage()
        }
        if type == .list || !searchText.isEmpty {
            // 搜索时，也必须按列表查看
            return getListNextPage()
        }
        return getGroupNextPage()
    }
    
    func transform(input: Input) -> Output {
        let alertMessage = input.itemSelected.map { [weak self] index in
            guard let results = self?.results else {
                return ("", 0)
            }
            let message = results[index]
            
            var copyContent: String = ""
            if let title = message.title {
                copyContent += "\(title)\n"
            }
            if let body = message.body {
                copyContent += "\(body)\n"
            }
            if let url = message.url {
                copyContent += "\(url)\n"
            }
            copyContent = String(copyContent.prefix(copyContent.count - 1))
            
            return (copyContent, index)
        }
        // 标题
        let titleRelay = BehaviorRelay<String>(value: NSLocalizedString("historyMessage"))
        // 数据源
        let messagesRelay = BehaviorRelay<[MessageSection]>(value: [])
        // 刷新操作
        let refreshAction = BehaviorRelay<MJRefreshAction>(value: .none)
        // 切换群组
        let filterGroups: BehaviorRelay<[String?]> = { [weak self] in
            guard let self = self else {
                return BehaviorRelay<[String?]>(value: [])
            }
            if case .group(let name) = self.sourceType {
                return BehaviorRelay<[String?]>(value: [name])
            }
            return BehaviorRelay<[String?]>(value: [])
        }()
        
        // 切换分组时，更新分组名
        filterGroups
            .subscribe(onNext: { filterGroups in
                if filterGroups.count <= 0 {
                    titleRelay.accept(NSLocalizedString("historyMessage"))
                } else {
                    titleRelay.accept(filterGroups.map { $0 ?? NSLocalizedString("default") }.joined(separator: " , "))
                }
            }).disposed(by: rx.disposeBag)
        
        // 切换分组和更改搜索词时，更新数据源
        Observable
            .combineLatest(filterGroups, input.searchText)
            .subscribe(onNext: { [weak self] groups, searchText in
                self?.searchText = searchText ?? ""
                self?.results = self?.getResults(filterGroups: groups, searchText: searchText)
                self?.groups = self?.getGroups()
            }).disposed(by: rx.disposeBag)

        // 群组筛选
        let messageTypeChanged = input.groupToggleTap.compactMap { () -> MessageListType? in
            self.type = self.type == .group ? .list : .group
            return self.type
        }

        // 切换分组和下拉刷新时，重新刷新列表
        Observable
            .merge(
                input.refresh.asObservable().map { () },
                filterGroups.map { _ in () },
                input.searchText.asObservable().map { _ in () },
                messageTypeChanged.asObservable().map { _ in () }
            )
            .subscribe(onNext: { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.page = 0
                let messages = strongSelf.getNextPage()
                messagesRelay.accept(
                    [MessageSection(header: "model", messages: messages)]
                )
                refreshAction.accept(.endRefresh)
            }).disposed(by: rx.disposeBag)
        
        // 加载更多
        // delay 是为了防止翻到 1+N 页时，切换分组操作（或其他）时会和 loadMore 同时触发，导致 Reentrancy anomaly，
        // APP闪退报 “UITableView is trying to layout cells with a global row ...”。
        input.loadMore.asObservable()
            .delay(.milliseconds(10), scheduler: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                guard let strongSelf = self else { return }
                let items = strongSelf.getNextPage()
                
                refreshAction.accept(.endLoadmore)
                if var section = messagesRelay.value.first {
                    section.messages.append(contentsOf: items)
                    messagesRelay.accept([section])
                } else {
                    messagesRelay.accept([MessageSection(header: "model", messages: items)])
                }
            }).disposed(by: rx.disposeBag)
        
        // 删除message
        input.itemDelete.drive(onNext: { [weak self] item in
            guard let self else { return }
            
            guard var section = messagesRelay.value.first else {
                return
            }
            
            // 根据类型删除数据
            switch item {
            case .message(let model):
                // 删除数据库对应消息
                if let realm = try? Realm(),
                   let message = realm.objects(Message.self).filter("id == %@", model.id).first
                {
                    try? realm.write {
                        realm.delete(message)
                    }
                }
                // 删除 cell item
                section.messages.removeAll { cellItem in
                    if case .message(let m) = cellItem {
                        return m.id == model.id
                    }
                    return false
                }
            case .messageGroup(let groupName, _, let messages):
                // 删除数据库中对应分组
                if let realm = try? Realm(), let first = messages.first {
                    let messageResult: Results<Message>?
                    if let group = first.group {
                        messageResult = self.results?.filter("group == %@", group)
                    } else {
                        messageResult = self.results?.filter("group == nil")
                    }
                    if let messageResult {
                        try? realm.write {
                            realm.delete(messageResult)
                        }
                    }
                }
                // 删除 cell item
                section.messages.removeAll { cellItem in
                    if case .messageGroup(let name, _, _) = cellItem {
                        return name == groupName
                    }
                    return false
                }
            }
            
            // 应用更改
            messagesRelay.accept([section])
            
        }).disposed(by: rx.disposeBag)
        
        // 批量删除
        input.delete.drive(onNext: { [weak self] type in
            guard let strongSelf = self else { return }
            
            var date = Date()
            switch type {
            case .allTime:
                date = Date(timeIntervalSince1970: 0)
            case .todayAndYesterday:
                date = Date.yesterday
            case .today:
                date = Date().noon
            case .lastHour:
                date = Date.lastHour
            }
            
            if let realm = try? Realm() {
                guard let messages = strongSelf.getResults(filterGroups: filterGroups.value, searchText: nil)?.filter("createDate >= %@", date) else {
                    return
                }
                
                try? realm.write {
                    realm.delete(messages)
                }
            }
            
            strongSelf.page = 0
            messagesRelay.accept([MessageSection(header: "model", messages: strongSelf.getNextPage())])
            
        }).disposed(by: rx.disposeBag)
        
        // 查看指定分组时，隐藏分组切换按钮
        let groupToggleButtonHidden = {
            if case .group = self.sourceType {
                return true
            }
            return false
        }()
        
        return Output(
            messages: messagesRelay.asDriver(onErrorJustReturn: []),
            refreshAction: refreshAction.asDriver(),
            alertMessage: alertMessage,
            type: Driver.merge(messageTypeChanged.asDriver(), Driver.just(self.type)),
            title: titleRelay.asDriver(),
            groupToggleButtonHidden: Driver.just(groupToggleButtonHidden)
        )
    }
}
