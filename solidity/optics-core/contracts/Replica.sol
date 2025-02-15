// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.6.11;

import "./Common.sol";
import "./Merkle.sol";
import {IMessageRecipient} from "../interfaces/IMessageRecipient.sol";

import "@summa-tx/memview-sol/contracts/TypedMemView.sol";

/**
 * @title Replica
 * @author Celo Labs Inc.
 * @notice Contract responsible for tracking root updates on home,
 * and dispatching messages on Replica to end recipients.
 */
contract Replica is Common {
    using QueueLib for QueueLib.Queue;
    using MerkleLib for MerkleLib.Tree;
    using TypedMemView for bytes;
    using TypedMemView for bytes29;
    using Message for bytes29;

    /// @notice Status of message
    enum MessageStatus {
        None,
        Pending,
        Processed
    }

    event ProcessSuccess(bytes32 indexed messageHash);

    event ProcessError(
        bytes32 indexed messageHash,
        uint32 indexed sequence,
        address indexed recipient,
        bytes returnData
    );

    /// @notice Minimum gas for message processing
    uint256 public constant PROCESS_GAS = 850000;

    /// @notice Reserved gas (to ensure tx completes in case message processing runs out)
    uint256 public constant RESERVE_GAS = 15000;

    /// @notice Domain of home chain
    uint32 public remoteDomain;

    /// @notice Number of seconds to wait before enqueued root becomes confirmable
    uint256 public optimisticSeconds;

    /// @notice Index of last processed message's leaf in home's merkle tree
    uint32 public nextToProcess;

    /// @notice Mapping of enqueued roots to allowable confirmation times
    mapping(bytes32 => uint256) public confirmAt;

    /// @dev re-entrancy guard
    uint8 private entered;

    /// @notice Mapping of message leaves to MessageStatus
    mapping(bytes32 => MessageStatus) public messages;

    uint256[44] private __GAP; // gap for upgrade safety

    constructor(uint32 _localDomain) Common(_localDomain) {} // solhint-disable-line no-empty-blocks

    function acceptableRoot(bytes32 _root) public view returns (bool) {
        uint256 _time = confirmAt[_root];
        if (_time == 0) {
            return false;
        }
        return block.timestamp >= _time;
    }

    function initialize(
        uint32 _remoteDomain,
        address _updater,
        bytes32 _current,
        uint256 _optimisticSeconds,
        uint32 _nextToProcess
    ) public initializer {
        __Common_initialize(_updater);

        entered = 1;
        remoteDomain = _remoteDomain;
        current = _current;
        confirmAt[_current] = 1;
        optimisticSeconds = _optimisticSeconds;
        nextToProcess = _nextToProcess;
    }

    /**
     * @notice Called by external agent. Enqueues signed update's new root,
     * marks root's allowable confirmation time, and emits an `Update` event.
     * @dev Reverts if update doesn't build off queue's last root or replica's
     * current root if queue is empty. Also reverts if signature is invalid.
     * @param _oldRoot Old merkle root
     * @param _newRoot New merkle root
     * @param _signature Updater's signature on `_oldRoot` and `_newRoot`
     **/
    function update(
        bytes32 _oldRoot,
        bytes32 _newRoot,
        bytes memory _signature
    ) external notFailed {
        if (queue.length() > 0) {
            require(_oldRoot == queue.lastItem(), "not end of queue");
        } else {
            require(current == _oldRoot, "not current update");
        }
        require(
            Common._isUpdaterSignature(_oldRoot, _newRoot, _signature),
            "bad sig"
        );

        // Hook for future use
        _beforeUpdate();

        // Set the new root's confirmation timer
        // And add the new root to the queue of roots
        confirmAt[_newRoot] = block.timestamp + optimisticSeconds;
        queue.enqueue(_newRoot);

        emit Update(remoteDomain, _oldRoot, _newRoot, _signature);
    }

    /**
     * @notice Called by external agent. Confirms as many confirmable roots in
     * queue as possible, updating replica's current root to be the last
     * confirmed root.
     * @dev Reverts if queue started as empty (i.e. no roots to confirm)
     **/
    function confirm() external notFailed {
        require(queue.length() != 0, "!pending");

        bytes32 _pending;

        // Traverse the queue by peeking each iterm to see if it ought to be
        // confirmed. If so, dequeue it
        uint256 _remaining = queue.length();
        while (_remaining > 0 && acceptableRoot(queue.peek())) {
            _pending = queue.dequeue();
            _remaining -= 1;
        }

        // This condition is hit if the while loop is never executed, because
        // the first queue item has not hit its timer yet
        require(_pending != bytes32(0), "!time");

        _beforeConfirm();

        current = _pending;
    }

    /**
     * @notice First attempts to prove the validity of provided formatted
     * `message`. If the message is successfully proven, then tries to process
     * message.
     * @dev Reverts if `prove` call returns false
     * @param _message Formatted message (refer to Common.sol Message library)
     * @param _proof Merkle proof of inclusion for message's leaf
     * @param _index Index of leaf in home's merkle tree
     **/
    function proveAndProcess(
        bytes memory _message,
        bytes32[32] calldata _proof,
        uint256 _index
    ) external {
        require(prove(keccak256(_message), _proof, _index), "!prove");
        process(_message);
    }

    /**
     * @notice Called by external agent. Returns next pending root to be
     * confirmed and its confirmation time. If queue is empty, returns null
     * values.
     * @return _pending Pending (unconfirmed) root
     * @return _confirmAt Pending root's confirmation time
     **/
    function nextPending()
        external
        view
        returns (bytes32 _pending, uint256 _confirmAt)
    {
        if (queue.length() != 0) {
            _pending = queue.peek();
            _confirmAt = confirmAt[_pending];
        } else {
            _pending = current;
            _confirmAt = confirmAt[current];
        }
    }

    /**
     * @notice Called by external agent. Returns true if there is a confirmable
     * root in the queue and false if otherwise.
     **/
    function canConfirm() external view returns (bool) {
        return queue.length() != 0 && acceptableRoot(queue.peek());
    }

    /**
     * @notice Given formatted message, attempts to dispatch message payload to
     * end recipient.
     * @dev Requires recipient to have implemented `handle` method (refer to
     * XAppConnectionManager.sol). Reverts if formatted message's destination domain
     * doesn't match replica's own domain, if message is out of order (skips
     * one or more sequence numbers), if message has not been proven (doesn't
     * have MessageStatus.Pending), or if not enough gas is provided for
     * dispatch transaction.
     * @param _message Formatted message (refer to Common.sol Message library)
     * @return _success True if dispatch transaction succeeded (false if
     * otherwise)
     **/
    function process(bytes memory _message) public returns (bool _success) {
        bytes29 _m = _message.ref(0);
        bytes32 _messageHash = _m.keccak();

        uint32 _sequence = _m.sequence();
        require(_m.destination() == localDomain, "!destination");
        require(messages[_messageHash] == MessageStatus.Pending, "!pending");

        require(entered == 1, "!reentrant");
        entered = 0;

        // update the status and next to process
        messages[_messageHash] = MessageStatus.Processed;
        nextToProcess = _sequence + 1;

        // NB:
        // A call running out of gas TYPICALLY errors the whole tx. We want to
        // a) ensure the call has a sufficient amount of gas to make a
        //    meaningful state change.
        // b) ensure that if the subcall runs out of gas, that the tx as a whole
        //    does not revert (i.e. we still mark the message processed)
        // To do this, we require that we have enough gas to process
        // and still return. We then delegate only the minimum processing gas.
        require(gasleft() >= PROCESS_GAS + RESERVE_GAS, "!gas");
        // transparently return.

        address _recipient = _m.recipientAddress();

        bytes memory _returnData;
        (_success, _returnData) = _recipient.call{gas: PROCESS_GAS}(
            abi.encodeWithSignature(
                "handle(uint32,bytes32,bytes)",
                _m.origin(),
                _m.sender(),
                _m.body().clone()
            )
        );

        if (_success) {
            emit ProcessSuccess(_messageHash);
        } else {
            emit ProcessError(_messageHash, _sequence, _recipient, _returnData);
        }

        entered = 1;
    }

    /**
     * @notice Attempts to prove the validity of message given its leaf, the
     * merkle proof of inclusion for the leaf, and the index of the leaf.
     * @dev Reverts if message's MessageStatus != None (i.e. if message was
     * already proven or processed)
     * @param _leaf Leaf of message to prove
     * @param _proof Merkle proof of inclusion for leaf
     * @param _index Index of leaf in home's merkle tree
     * @return Returns true if proof was valid and `prove` call succeeded
     **/
    function prove(
        bytes32 _leaf,
        bytes32[32] calldata _proof,
        uint256 _index
    ) public returns (bool) {
        require(messages[_leaf] == MessageStatus.None, "!MessageStatus.None");
        bytes32 _actual = MerkleLib.branchRoot(_leaf, _proof, _index);

        // NB:
        // For convenience, we allow proving against any previous root.
        // This means that witnesses never need to be updated for the new root
        if (acceptableRoot(_actual)) {
            messages[_leaf] = MessageStatus.Pending;
            return true;
        }
        return false;
    }

    /// @notice Hash of Home's domain concatenated with "OPTICS"
    function homeDomainHash() public view override returns (bytes32) {
        return _homeDomainHash(remoteDomain);
    }

    /// @notice Sets contract state to FAILED
    function _fail() internal override {
        _setFailed();
    }

    /// @notice Hook for potential future use
    // solhint-disable-next-line no-empty-blocks
    function _beforeConfirm() internal {}

    /// @notice Hook for potential future use
    // solhint-disable-next-line no-empty-blocks
    function _beforeUpdate() internal {}
}
