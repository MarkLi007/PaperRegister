// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PaperRegistryAdvancedMultiAuditor
 * @notice 在原有基础上添加: 多审稿人管理(可动态增删)、防重复上传、审稿审核流程、多版本、签名
 */
contract PaperRegistryAdvancedMultiAuditor is Ownable {
    /**
     * @dev 审稿人集合：mapping记录哪些地址是审稿人
     */
    mapping(address => bool) public auditors;

    /**
     * @dev 状态：PENDING(待审)、PUBLISHED(已发布)、REJECTED(审核驳回)、REMOVED(作者移除)
     */
    enum PaperStatus { PENDING, PUBLISHED, REJECTED, REMOVED }

    /**
     * @dev 版本信息
     *  - ipfsHash: PDF在IPFS的CID
     *  - fileHash: PDF文件做keccak256得到的哈希(用于防止重复)
     *  - timestamp: 此版本提交区块时间
     *  - signature: 前端离线签名(可选)
     */
    struct Version {
        string ipfsHash;
        bytes32 fileHash;
        uint256 timestamp;
        bytes signature;
    }

    /**
     * @dev 论文主要结构
     *  - paperOwner: 论文作者
     *  - title, author: 论文基本信息
     *  - versions: 版本列表(首个版本+后续版本)
     *  - status: 当前状态(待审/已发布/驳回/移除)
     */
    struct Paper {
        address paperOwner;
        string title;
        string author;
        Version[] versions;
        PaperStatus status;
    }

    /// paperId => Paper
    mapping(uint256 => Paper) public papers;

    /// 论文总数(自增)
    uint256 public paperCount;

    /// 用于“防止重复”功能：只有在PUBLISHED时记录 fileHash => true, 防他人重复
    mapping(bytes32 => bool) public usedFileHash;

    /**
     * @dev 构造函数：初始化owner,无审稿人
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice 添加审稿人(仅owner可执行)
     * @param _auditor 新审稿人地址
     */
    function addAuditor(address _auditor) external onlyOwner {
        require(_auditor != address(0), "Invalid auditor address");
        require(!auditors[_auditor], "Already an auditor");
        auditors[_auditor] = true;
        emit AuditorAdded(_auditor);
    }

    /**
     * @notice 移除审稿人(仅owner可执行)
     * @param _auditor 被移除地址
     */
    function removeAuditor(address _auditor) external onlyOwner {
        require(auditors[_auditor], "Not an auditor");
        auditors[_auditor] = false;
        emit AuditorRemoved(_auditor);
    }

    /**
     * @dev 修饰器: 只有审稿人或owner可调用
     */
    modifier onlyAuditorOrOwner() {
        require(msg.sender == owner() || auditors[msg.sender], "Not auditor or owner");
        _;
    }

    /**
     * @notice 提交论文(处于“待审”状态)
     * @param _title 标题
     * @param _author 作者(字符串)
     * @param _ipfsHash 首次版本PDF在IPFS的CID
     * @param _fileHash PDF文件hash(keccak256)
     * @param _signature 可选签名
     */
    function submitPaper(
        string memory _title,
        string memory _author,
        string memory _ipfsHash,
        bytes32 _fileHash,
        bytes memory _signature
    ) external {
        paperCount++;
        Paper storage p = papers[paperCount];
        p.paperOwner = msg.sender;
        p.title = _title;
        p.author = _author;
        p.status = PaperStatus.PENDING;

        // 创建初始版本
        Version memory v;
        v.ipfsHash = _ipfsHash;
        v.fileHash = _fileHash;
        v.timestamp = block.timestamp;
        v.signature = _signature;
        p.versions.push(v);

        emit PaperSubmitted(
            paperCount,
            _title,
            _author,
            _ipfsHash,
            _fileHash,
            block.timestamp,
            _signature
        );
    }

    /**
     * @notice 审批(审稿人或owner): 审核通过 => PUBLISHED
     * @param _paperId 论文ID
     */
    function approvePaper(uint256 _paperId) external onlyAuditorOrOwner {
        require(_paperId > 0 && _paperId <= paperCount, "Invalid paperId");
        Paper storage p = papers[_paperId];
        require(p.status == PaperStatus.PENDING, "Paper not in pending");

        // 初次版本(索引0)
        Version storage v0 = p.versions[0];
        bytes32 fHash = v0.fileHash;

        require(!usedFileHash[fHash], "fileHash used by another paper");

        p.status = PaperStatus.PUBLISHED;
        usedFileHash[fHash] = true;

        emit PaperApproved(_paperId, block.timestamp);
    }

    /**
     * @notice 审批(审稿人或owner): 审核拒绝 => REJECTED
     * @param _paperId 论文ID
     */
    function rejectPaper(uint256 _paperId) external onlyAuditorOrOwner {
        require(_paperId > 0 && _paperId <= paperCount, "Invalid paperId");
        Paper storage p = papers[_paperId];
        require(p.status == PaperStatus.PENDING, "Paper not in pending");

        p.status = PaperStatus.REJECTED;
        emit PaperRejected(_paperId, block.timestamp);
    }

    /**
     * @notice 作者自己移除论文 => REMOVED(不再展示)
     * @param _paperId 论文ID
     */
    function removePaper(uint256 _paperId) external {
        require(_paperId > 0 && _paperId <= paperCount, "Invalid paperId");
        Paper storage p = papers[_paperId];
        require(p.status != PaperStatus.REMOVED, "Already removed");
        require(p.paperOwner == msg.sender, "Not paper owner");

        p.status = PaperStatus.REMOVED;
        emit PaperRemoved(_paperId, block.timestamp);
    }

    /**
     * @notice 给已发布论文添加新版本, 仅作者可调用, 状态必须PUBLISHED
     * @param _paperId 论文ID
     * @param _ipfsHash 新版本PDF在IPFS的CID
     * @param _fileHash 新版本PDF文件hash
     * @param _signature 可选签名
     */
    function addVersion(
        uint256 _paperId,
        string memory _ipfsHash,
        bytes32 _fileHash,
        bytes memory _signature
    ) external {
        require(_paperId > 0 && _paperId <= paperCount, "Invalid paperId");
        Paper storage p = papers[_paperId];
        require(p.status == PaperStatus.PUBLISHED, "Not published");
        require(p.paperOwner == msg.sender, "Not paper owner");

        Version memory v;
        v.ipfsHash = _ipfsHash;
        v.fileHash = _fileHash;
        v.timestamp = block.timestamp;
        v.signature = _signature;
        p.versions.push(v);

        emit VersionAdded(
            _paperId,
            p.versions.length - 1,
            _ipfsHash,
            _fileHash,
            block.timestamp,
            _signature
        );
    }

    /**
     * @notice 获取论文基础信息(不含版本详情)
     * @param _paperId 论文ID
     * @return paperOwner 论文作者地址
     * @return title 论文标题
     * @return author 论文作者(字符串)
     * @return status 论文状态:0=PENDING,1=PUBLISHED,2=REJECTED,3=REMOVED
     * @return versionCount 版本数量
     */
    function getPaperInfo(uint256 _paperId)
        external
        view
        returns (
            address paperOwner,
            string memory title,
            string memory author,
            uint8 status,
            uint256 versionCount
        )
    {
        require(_paperId > 0 && _paperId <= paperCount, "Invalid paperId");
        Paper storage p = papers[_paperId];
        paperOwner = p.paperOwner;
        title = p.title;
        author = p.author;
        status = uint8(p.status);
        versionCount = p.versions.length;
    }

    /**
     * @notice 获取某个版本详情
     * @param _paperId 论文ID
     * @param _verIndex 版本索引
     * @return ipfsHash IPFS哈希
     * @return fileHash PDF文件hash
     * @return timestamp 版本时间
     * @return signature 离线签名(可选)
     */
    function getVersion(uint256 _paperId, uint256 _verIndex)
        external
        view
        returns (
            string memory ipfsHash,
            bytes32 fileHash,
            uint256 timestamp,
            bytes memory signature
        )
    {
        require(_paperId > 0 && _paperId <= paperCount, "Invalid paperId");
        Paper storage pap = papers[_paperId];
        require(_verIndex < pap.versions.length, "Version out of range");

        Version storage v = pap.versions[_verIndex];
        ipfsHash = v.ipfsHash;
        fileHash = v.fileHash;
        timestamp = v.timestamp;
        signature = v.signature;
    }

    //=================== 事件列表 ===================

    event AuditorAdded(address indexed auditorAddr);
    event AuditorRemoved(address indexed auditorAddr);

    event PaperSubmitted(
        uint256 indexed paperId,
        string title,
        string author,
        string ipfsHash,
        bytes32 fileHash,
        uint256 timestamp,
        bytes signature
    );

    event PaperApproved(uint256 indexed paperId, uint256 timestamp);
    event PaperRejected(uint256 indexed paperId, uint256 timestamp);
    event PaperRemoved(uint256 indexed paperId, uint256 timestamp);

    event VersionAdded(
        uint256 indexed paperId,
        uint256 versionIndex,
        string ipfsHash,
        bytes32 fileHash,
        uint256 timestamp,
        bytes signature
    );
}
