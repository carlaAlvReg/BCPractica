// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FoodTraceability
 * @notice Prototipo de trazabilidad de lotes e ingredientes para una red EVM.
 * @dev Los datos son declaraciones de los operadores: el contrato no verifica
 *      por si mismo la localizacion fisica ni la composicion real del producto.
 */
contract FoodTraceability {
    uint256 public constant MAX_INGREDIENTS = 20;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_LOCATION_BYTES = 80;

    address public immutable admin;
    uint256 public nextBatchId = 1;

    struct Batch {
        string name;
        address creator;
        address custodian;
        address pendingRecipient;
        uint64 createdAt;
        bool isProduct;
    }

    struct Step {
        address operator;
        uint64 timestamp;
        string location;
    }

    mapping(address => bool) public operators;
    mapping(uint256 => Batch) public batches;
    mapping(uint256 => uint256[]) private batchIngredients;
    mapping(uint256 => Step[]) private batchSteps;
    mapping(address => string) public operatorNames;

    error OnlyAdmin();
    error UnauthorizedOperator();
    error InvalidAddress();
    error InvalidText();
    error TooManyIngredients();
    error BatchNotFound(uint256 batchId);
    error InvalidIngredient(uint256 ingredientId);
    error DuplicateIngredient(uint256 ingredientId);
    error NotCustodian(uint256 batchId);
    error InvalidRecipient();
    error TransferAlreadyPending();
    error NoPendingTransfer();
    error NotAssignedRecipient();
    error StepNotFound(uint256 batchId, uint256 index);

    event OperatorUpdated(address indexed operator, bool authorized);
    event OperatorNameUpdated(address indexed operator, string name);
    event BatchCreated(uint256 indexed batchId, address indexed creator, bool isProduct);
    event StepRecorded(uint256 indexed batchId, address indexed operator, uint256 index);
    event TransferProposed(
        uint256 indexed batchId,
        address indexed from,
        address indexed to
    );
    event TransferCancelled(uint256 indexed batchId, address indexed by);
    event TransferAccepted(
        uint256 indexed batchId,
        address indexed from,
        address indexed to
    );

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert UnauthorizedOperator();
        _;
    }

    modifier onlyCustodian(uint256 batchId) {
        _requireBatch(batchId);
        if (batches[batchId].custodian != msg.sender) revert NotCustodian(batchId);
        _;
    }

    constructor() {
        admin = msg.sender;
        operators[msg.sender] = true;
        operatorNames[msg.sender] = "Administrador";
        emit OperatorNameUpdated(msg.sender, "Administrador");
        emit OperatorUpdated(msg.sender, true);
    }

    /// @notice El administrador registra o actualiza el nombre y autoriza al operador.
    /// @dev Registrar de nuevo una direccion actualiza el nombre y la vuelve a autorizar.
    function registerOperator(address operator, string calldata name)
        external
        onlyAdmin
    {
        if (operator == address(0)) revert InvalidAddress();
        _validateText(name, MAX_NAME_BYTES);
        operatorNames[operator] = name;
        operators[operator] = true;
        emit OperatorNameUpdated(operator, name);
        emit OperatorUpdated(operator, true);
    }

    /// @notice El administrador permite o revoca el acceso de un operador.
    /// @dev Conserva el nombre al revocar para poder identificar registros anteriores.
    function setOperator(address operator, bool authorized)
        external
        onlyAdmin
    {
        if (operator == address(0)) revert InvalidAddress();
        operators[operator] = authorized;
        emit OperatorUpdated(operator, authorized);
    }

    /**
     * @notice Crea un lote de materia prima (sin ingredientes) o de producto
     *         elaborado (con ingredientes previamente registrados).
     * @param name Denominacion del lote o producto.
     * @param initialLocation Lugar donde se declara su creacion.
     * @param ingredients IDs de lotes de entrada bajo custodia del creador.
     * @return batchId Identificador unico y correlativo del nuevo lote.
     */
    function createBatch(
        string calldata name,
        string calldata initialLocation,
        uint256[] calldata ingredients
    ) external onlyOperator returns (uint256 batchId) {
        _validateText(name, MAX_NAME_BYTES);
        _validateText(initialLocation, MAX_LOCATION_BYTES);
        if (ingredients.length > MAX_INGREDIENTS) {
            revert TooManyIngredients();
        }

        batchId = nextBatchId;
        // Los lotes de entrada deben tener un ID menor que el lote nuevo:
        // la relacion de procedencia nunca puede formar ciclos.
        for (uint256 i; i < ingredients.length; ) {
            uint256 ingredientId = ingredients[i];
            if (ingredientId == 0 || ingredientId >= batchId) {
                revert InvalidIngredient(ingredientId);
            }
            if (batches[ingredientId].custodian != msg.sender) {
                revert NotCustodian(ingredientId);
            }
            for (uint256 j; j < i; ) {
                if (ingredients[j] == ingredientId) {
                    revert DuplicateIngredient(ingredientId);
                }
                unchecked { ++j; }
            }
            batchIngredients[batchId].push(ingredientId);
            unchecked { ++i; }
        }

        // El contador solo avanza en transacciones que llegan a completarse.
        nextBatchId = batchId + 1;
        Batch storage batch = batches[batchId];
        batch.name = name;
        batch.creator = msg.sender;
        batch.custodian = msg.sender;
        batch.createdAt = uint64(block.timestamp);
        batch.isProduct = ingredients.length != 0;

        _recordStep(batchId, initialLocation);
        emit BatchCreated(batchId, msg.sender, batch.isProduct);
    }

    /// @notice Agrega un punto de paso declarado por quien custodia el lote.
    function recordStep(uint256 batchId, string calldata location)
        external
        onlyOperator
        onlyCustodian(batchId)
    {
        _validateText(location, MAX_LOCATION_BYTES);
        _recordStep(batchId, location);
    }

    /// @notice Propone una transferencia que el destinatario debe aceptar.
    function proposeTransfer(uint256 batchId, address recipient)
        external
        onlyOperator
        onlyCustodian(batchId)
    {
        if (!operators[recipient] || recipient == msg.sender) {
            revert InvalidRecipient();
        }
        Batch storage batch = batches[batchId];
        if (batch.pendingRecipient != address(0)) {
            revert TransferAlreadyPending();
        }
        batch.pendingRecipient = recipient;
        emit TransferProposed(batchId, msg.sender, recipient);
    }

    /// @notice Cancela la propuesta vigente antes de ser aceptada.
    function cancelTransfer(uint256 batchId)
        external
        onlyOperator
        onlyCustodian(batchId)
    {
        if (batches[batchId].pendingRecipient == address(0)) {
            revert NoPendingTransfer();
        }
        delete batches[batchId].pendingRecipient;
        emit TransferCancelled(batchId, msg.sender);
    }

    /// @notice El receptor acepta la custodia y declara su punto de recepcion.
    function acceptTransfer(uint256 batchId, string calldata location)
        external
        onlyOperator
    {
        _requireBatch(batchId);
        _validateText(location, MAX_LOCATION_BYTES);
        Batch storage batch = batches[batchId];
        if (batch.pendingRecipient != msg.sender) revert NotAssignedRecipient();

        address previous = batch.custodian;
        batch.custodian = msg.sender;
        delete batch.pendingRecipient;
        _recordStep(batchId, location);
        emit TransferAccepted(batchId, previous, msg.sender);
    }

    /// @notice Devuelve los identificadores de los lotes de entrada.
    function getIngredients(uint256 batchId)
        external
        view
        returns (uint256[] memory)
    {
        _requireBatch(batchId);
        return batchIngredients[batchId];
    }

    /// @notice Devuelve el numero de lugares/etapas registrados para un lote.
    function stepCount(uint256 batchId) external view returns (uint256) {
        _requireBatch(batchId);
        return batchSteps[batchId].length;
    }

    /// @notice Consulta un paso por posicion, empezando en indice cero.
    function getStep(uint256 batchId, uint256 index)
        external
        view
        returns (address operator, uint64 timestamp, string memory location)
    {
        _requireBatch(batchId);
        if (index >= batchSteps[batchId].length) {
            revert StepNotFound(batchId, index);
        }
        Step storage step = batchSteps[batchId][index];
        return (step.operator, step.timestamp, step.location);
    }

    function _requireBatch(uint256 batchId) internal view {
        if (batches[batchId].creator == address(0)) revert BatchNotFound(batchId);
    }

    function _validateText(string calldata text, uint256 maxBytes) internal pure {
        uint256 length = bytes(text).length;
        if (length == 0 || length > maxBytes) revert InvalidText();
    }

    function _recordStep(uint256 batchId, string calldata location) internal {
        uint256 index = batchSteps[batchId].length;
        batchSteps[batchId].push(
            Step({
                operator: msg.sender,
                timestamp: uint64(block.timestamp),
                location: location
            })
        );
        emit StepRecorded(batchId, msg.sender, index);
    }
}
