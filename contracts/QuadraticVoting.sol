// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import "./VotingToken.sol";
import "./IExecutableProposal.sol";

/*
 * Contrato principal del proyecto.
 *
 * Gestiona:
 * - participantes;
 * - compra y venta de tokens;
 * - apertura y cierre de rondas de votacion;
 * - creacion de propuestas;
 * - votacion cuadratica;
 * - ejecucion de propuestas de financiacion;
 * - ejecucion de propuestas de signaling;
 * - devolucion de tokens mediante pull-over-push.
 */
contract QuadraticVoting {
    /*
     * Limite de gas para ejecutar contratos externos de propuesta.
     * El enunciado pide que executeProposal no pueda consumir mas de 100000 gas.
     */
    uint public constant EXECUTION_GAS_LIMIT = 100000;

    /*
     * Escala para representar decimales.
     * 0.2 se representa como 200 / 1000.
     */
    uint private constant THRESHOLD_SCALE = 1000;
    uint private constant THRESHOLD_BASE = 200;

    address payable public immutable owner;
    VotingToken private immutable votingToken;

    uint public immutable tokenPrice;

    uint public currentRoundId;
    uint public totalBudget;
    uint public numParticipants;
    uint public numPendingFundingProposals;

    uint private nextProposalId;
    bool private locked;

    enum RoundStatus {
        NotStarted,
        Open,
        Closed
    }

    enum ProposalStatus {
        Pending,
        Approved,
        Cancelled
    }

    /*
     * Datos de una propuesta.
     *
     * El identificador de la propuesta no se guarda dentro del struct porque
     * ya es la clave del mapping proposals[proposalId].
     */
    struct Proposal {
        uint roundId;
        string title;
        string description;
        uint budget;
        address creator;
        address executableContract;
        uint totalVotes;
        uint totalTokensStaked;
        bool isSignaling;
        bool signalingExecuted;
        ProposalStatus status;
    }

    mapping(uint => RoundStatus) private roundStatus;
    mapping(address => bool) public isParticipant;

    mapping(uint => Proposal) private proposals;

    mapping(uint => uint[]) private fundingProposalsByRound;
    mapping(uint => uint[]) private approvedProposalsByRound;
    mapping(uint => uint[]) private signalingProposalsByRound;

    mapping(uint => mapping(address => uint)) private votesOf;
    mapping(uint => mapping(address => uint)) private tokensStakedOf;
    mapping(uint => mapping(address => bool)) private refundClaimed;

    event VotingOpened(uint indexed roundId, uint initialBudget);
    event VotingClosed(uint indexed roundId, uint remainingBudget);

    event ParticipantAdded(address indexed participant, uint tokensBought);
    event ParticipantRemoved(address indexed participant);

    event TokensBought(address indexed participant, uint numTokens);
    event TokensSold(address indexed participant, uint numTokens);

    event ProposalAdded(
        uint indexed proposalId,
        uint indexed roundId,
        address indexed creator,
        uint budget,
        bool isSignaling
    );

    event ProposalCancelled(uint indexed proposalId);
    event ProposalApproved(uint indexed proposalId, uint numVotes, uint numTokens);
    event SignalingProposalExecuted(uint indexed proposalId);

    event VotesStaked(
        address indexed participant,
        uint indexed proposalId,
        uint votesAdded,
        uint tokensPaid
    );

    event VotesWithdrawn(
        address indexed participant,
        uint indexed proposalId,
        uint votesWithdrawn,
        uint tokensReturned
    );

    event RefundClaimed(
        address indexed participant,
        uint indexed proposalId,
        uint tokensReturned
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Solo creador");
        _;
    }

    modifier onlyParticipant() {
        require(isParticipant[msg.sender], "Solo participantes");
        _;
    }

    modifier votingOpen() {
        require(roundStatus[currentRoundId] == RoundStatus.Open, "Votacion cerrada");
        _;
    }

    modifier votingClosed(uint roundId) {
        require(roundStatus[roundId] == RoundStatus.Closed, "Votacion abierta");
        _;
    }

    modifier validProposal(uint proposalId) {
        require(proposalId < nextProposalId, "Propuesta invalida");
        _;
    }

    /*
     * Bloqueo anti-reentrancy simple.
     */
    modifier nonReentrant() {
        require(!locked, "Reentrancy");

        locked = true;
        _;
        locked = false;
    }

    constructor(uint tokenPrice_, uint maxTokens_) {
        require(tokenPrice_ > 0, "Precio invalido");
        require(maxTokens_ > 0, "Maximo invalido");

        owner = payable(msg.sender);
        tokenPrice = tokenPrice_;

        votingToken = new VotingToken(maxTokens_, address(this));
    }

    /*
     * Se evita recibir Ether sin actualizar la contabilidad interna.
     */
    receive() external payable {
        revert("Funcion invalida");
    }

    /*
     * Devuelve la direccion del contrato ERC20.
     * Los participantes la necesitan para hacer approve antes de stake.
     */
    function getERC20() external view returns (address) {
        return address(votingToken);
    }

    /*
     * Abre una nueva ronda de votacion.
     * El Ether enviado es el presupuesto inicial.
     */
    function openVoting() external payable onlyOwner {
        require(roundStatus[currentRoundId] != RoundStatus.Open, "Ya abierta");
        require(msg.value > 0, "Presupuesto invalido");

        currentRoundId++;
        totalBudget = msg.value;
        numPendingFundingProposals = 0;

        roundStatus[currentRoundId] = RoundStatus.Open;

        emit VotingOpened(currentRoundId, msg.value);
    }

    /*
     * Cierra la votacion.
     *
     * Pull-over-push:
     * - No recorre votantes.
     * - No devuelve todos los tokens aqui.
     * - Solo cambia el estado y devuelve el presupuesto restante.
     */
    function closeVoting() external onlyOwner votingOpen nonReentrant {
        uint roundId = currentRoundId;
        uint remainingBudget = totalBudget;

        roundStatus[roundId] = RoundStatus.Closed;
        totalBudget = 0;
        numPendingFundingProposals = 0;

        if (remainingBudget > 0) {
            (bool success, ) = owner.call{value: remainingBudget}("");
            require(success, "Envio fallido");
        }

        emit VotingClosed(roundId, remainingBudget);
    }

    /*
     * Registra un participante comprando al menos un token.
     */
    function addParticipant() external payable {
        require(!isParticipant[msg.sender], "Ya registrado");

        uint tokensBought = _buyTokensFor(msg.sender, msg.value);

        isParticipant[msg.sender] = true;
        numParticipants++;

        emit ParticipantAdded(msg.sender, tokensBought);
    }

    /*
     * El participante deja de estar activo.
     * No se destruyen sus tokens ni se borran sus votos.
     */
    function removeParticipant() external onlyParticipant {
        isParticipant[msg.sender] = false;
        numParticipants--;

        emit ParticipantRemoved(msg.sender);
    }

    /*
     * Compra mas tokens.
     */
    function buyTokens() external payable onlyParticipant {
        uint tokensBought = _buyTokensFor(msg.sender, msg.value);

        emit TokensBought(msg.sender, tokensBought);
    }

    /*
     * Vende tokens no bloqueados y recupera Ether.
     */
    function sellTokens(uint numTokens) external onlyParticipant nonReentrant {
        require(numTokens > 0, "Cantidad invalida");
        require(votingToken.balanceOf(msg.sender) >= numTokens, "Tokens insuficientes");

        uint etherAmount = numTokens * tokenPrice;

        require(_availableEtherForTokenSales() >= etherAmount, "Reserva insuficiente");

        votingToken.burn(msg.sender, numTokens);

        (bool success, ) = payable(msg.sender).call{value: etherAmount}("");
        require(success, "Envio fallido");

        emit TokensSold(msg.sender, numTokens);
    }

    /*
     * Crea una propuesta.
     *
     * budget == 0  -> signaling.
     * budget > 0   -> financiacion.
     */
    function addProposal(
        string calldata title,
        string calldata description,
        uint budget,
        address executableContract
    ) external onlyParticipant votingOpen returns (uint) {
        require(bytes(title).length > 0, "Titulo vacio");
        require(executableContract != address(0), "Contrato invalido");
        require(_supportsExecutableProposal(executableContract), "Interfaz invalida");

        uint proposalId = nextProposalId;
        nextProposalId++;

        bool isSignaling = (budget == 0);

        proposals[proposalId] = Proposal({
            roundId: currentRoundId,
            title: title,
            description: description,
            budget: budget,
            creator: msg.sender,
            executableContract: executableContract,
            totalVotes: 0,
            totalTokensStaked: 0,
            isSignaling: isSignaling,
            signalingExecuted: false,
            status: ProposalStatus.Pending
        });

        if (isSignaling) {
            signalingProposalsByRound[currentRoundId].push(proposalId);
        } else {
            fundingProposalsByRound[currentRoundId].push(proposalId);
            numPendingFundingProposals++;
        }

        emit ProposalAdded(
            proposalId,
            currentRoundId,
            msg.sender,
            budget,
            isSignaling
        );

        return proposalId;
    }

    /*
     * Cancela una propuesta pendiente.
     *
     * Pull-over-push:
     * no se devuelven aqui los tokens; cada votante reclama con claimRefund.
     */
    function cancelProposal(uint proposalId)
        external
        votingOpen
        validProposal(proposalId)
    {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.roundId == currentRoundId, "Ronda incorrecta");
        require(msg.sender == proposal.creator, "Solo creador");
        require(proposal.status == ProposalStatus.Pending, "No pendiente");

        proposal.status = ProposalStatus.Cancelled;

        if (!proposal.isSignaling) {
            numPendingFundingProposals--;
        }

        emit ProposalCancelled(proposalId);
    }

    /*
     * Deposita votos en una propuesta.
     *
     * El coste adicional se calcula como:
     *      nuevosVotos^2 - votosAnteriores^2
     */
    function stake(uint proposalId, uint votes)
        external
        onlyParticipant
        votingOpen
        validProposal(proposalId)
        nonReentrant
    {
        require(votes > 0, "Votos invalidos");

        Proposal storage proposal = proposals[proposalId];

        require(proposal.roundId == currentRoundId, "Ronda incorrecta");
        require(proposal.status == ProposalStatus.Pending, "No pendiente");

        uint previousVotes = votesOf[proposalId][msg.sender];
        uint newVotes = previousVotes + votes;
        uint tokensToPay = _quadraticCost(previousVotes, newVotes);

        require(
            votingToken.allowance(msg.sender, address(this)) >= tokensToPay,
            "Allowance insuficiente"
        );

        bool transferred = votingToken.transferFrom(
            msg.sender,
            address(this),
            tokensToPay
        );

        require(transferred, "Transferencia fallida");

        votesOf[proposalId][msg.sender] = newVotes;
        tokensStakedOf[proposalId][msg.sender] += tokensToPay;

        proposal.totalVotes += votes;
        proposal.totalTokensStaked += tokensToPay;

        emit VotesStaked(msg.sender, proposalId, votes, tokensToPay);

        if (!proposal.isSignaling) {
            _checkAndExecuteProposal(proposalId);
        }
    }

    /*
     * Retira votos de una propuesta pendiente.
     */
    function withdrawFromProposal(uint proposalId, uint votes)
        external
        onlyParticipant
        votingOpen
        validProposal(proposalId)
        nonReentrant
    {
        require(votes > 0, "Votos invalidos");

        Proposal storage proposal = proposals[proposalId];

        require(proposal.roundId == currentRoundId, "Ronda incorrecta");
        require(proposal.status == ProposalStatus.Pending, "No pendiente");

        uint previousVotes = votesOf[proposalId][msg.sender];

        require(previousVotes >= votes, "Votos insuficientes");

        uint newVotes = previousVotes - votes;
        uint tokensToReturn = _quadraticCost(newVotes, previousVotes);

        votesOf[proposalId][msg.sender] = newVotes;
        tokensStakedOf[proposalId][msg.sender] -= tokensToReturn;

        proposal.totalVotes -= votes;
        proposal.totalTokensStaked -= tokensToReturn;

        bool transferred = votingToken.transfer(msg.sender, tokensToReturn);
        require(transferred, "Transferencia fallida");

        emit VotesWithdrawn(msg.sender, proposalId, votes, tokensToReturn);
    }

    /*
     * Reclama tokens bloqueados en una propuesta cancelada o no aprobada.
     */
    function claimRefund(uint proposalId)
        external
        validProposal(proposalId)
        nonReentrant
    {
        Proposal storage proposal = proposals[proposalId];

        require(_canClaimRefund(proposal), "No reembolsable");
        require(!refundClaimed[proposalId][msg.sender], "Ya reclamado");

        uint tokensToReturn = tokensStakedOf[proposalId][msg.sender];

        require(tokensToReturn > 0, "Sin tokens");

        refundClaimed[proposalId][msg.sender] = true;
        tokensStakedOf[proposalId][msg.sender] = 0;
        votesOf[proposalId][msg.sender] = 0;

        bool transferred = votingToken.transfer(msg.sender, tokensToReturn);
        require(transferred, "Transferencia fallida");

        emit RefundClaimed(msg.sender, proposalId, tokensToReturn);
    }

    /*
     * Ejecuta una propuesta de signaling despues del cierre.
     */
    function executeSignalingProposal(uint proposalId)
        external
        validProposal(proposalId)
        votingClosed(proposals[proposalId].roundId)
        nonReentrant
    {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.isSignaling, "No signaling");
        require(proposal.status == ProposalStatus.Pending, "No pendiente");
        require(!proposal.signalingExecuted, "Ya ejecutada");

        proposal.signalingExecuted = true;

        IExecutableProposal(proposal.executableContract).executeProposal{
            value: 0,
            gas: EXECUTION_GAS_LIMIT
        }(
            proposalId,
            proposal.totalVotes,
            proposal.totalTokensStaked
        );

        emit SignalingProposalExecuted(proposalId);
    }

    /*
     * Devuelve las propuestas de financiacion pendientes de la ronda actual.
     */
    function getPendingProposals()
        external
        view
        votingOpen
        returns (uint[] memory)
    {
        uint[] storage allFundingProposals = fundingProposalsByRound[currentRoundId];

        uint pendingCount = 0;

        for (uint i = 0; i < allFundingProposals.length; i++) {
            if (proposals[allFundingProposals[i]].status == ProposalStatus.Pending) {
                pendingCount++;
            }
        }

        uint[] memory pendingProposals = new uint[](pendingCount);
        uint index = 0;

        for (uint i = 0; i < allFundingProposals.length; i++) {
            uint proposalId = allFundingProposals[i];

            if (proposals[proposalId].status == ProposalStatus.Pending) {
                pendingProposals[index] = proposalId;
                index++;
            }
        }

        return pendingProposals;
    }

    /*
     * Devuelve las propuestas de financiacion aprobadas de la ronda actual.
     */
    function getApprovedProposals()
        external
        view
        votingOpen
        returns (uint[] memory)
    {
        return approvedProposalsByRound[currentRoundId];
    }

    /*
     * Devuelve las propuestas de signaling de la ronda actual.
     */
    function getSignalingProposals()
        external
        view
        votingOpen
        returns (uint[] memory)
    {
        return signalingProposalsByRound[currentRoundId];
    }

    /*
     * Devuelve los datos de una propuesta.
     *
     * Devolvemos el struct completo para evitar Stack too deep y reducir bytecode.
     */
    function getProposalInfo(uint proposalId)
        external
        view
        votingOpen
        validProposal(proposalId)
        returns (Proposal memory)
    {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.roundId == currentRoundId, "Ronda incorrecta");

        return proposal;
    }

    /*
     * Comprueba si una propuesta de financiacion debe aprobarse.
     */
    function _checkAndExecuteProposal(uint proposalId) internal {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.isSignaling) {
            return;
        }

        if (proposal.status != ProposalStatus.Pending) {
            return;
        }

        if (totalBudget < proposal.budget) {
            return;
        }

        uint threshold = _calculateThreshold(proposal.budget);

        if (proposal.totalVotes <= threshold) {
            return;
        }

        uint proposalBudget = proposal.budget;
        uint tokensToConsume = proposal.totalTokensStaked;
        uint etherFromTokens = tokensToConsume * tokenPrice;

        proposal.status = ProposalStatus.Approved;
        numPendingFundingProposals--;

        approvedProposalsByRound[proposal.roundId].push(proposalId);

        totalBudget = totalBudget + etherFromTokens - proposalBudget;

        votingToken.burn(address(this), tokensToConsume);

        IExecutableProposal(proposal.executableContract).executeProposal{
            value: proposalBudget,
            gas: EXECUTION_GAS_LIMIT
        }(
            proposalId,
            proposal.totalVotes,
            tokensToConsume
        );

        emit ProposalApproved(proposalId, proposal.totalVotes, tokensToConsume);
    }

    /*
     * Formula del umbral:
     * (0.2 + budget_i / totalBudget) * numParticipants + numPendingProposals
     */
    function _calculateThreshold(uint proposalBudget) internal view returns (uint) {
        require(totalBudget > 0, "Sin presupuesto");

        uint variablePart = (proposalBudget * THRESHOLD_SCALE) / totalBudget;

        return (
            (THRESHOLD_BASE + variablePart) * numParticipants
        ) / THRESHOLD_SCALE + numPendingFundingProposals;
    }

    /*
     * Diferencia entre coste nuevo y coste anterior.
     */
    function _quadraticCost(
        uint oldVotes,
        uint newVotes
    ) internal pure returns (uint) {
        return (newVotes * newVotes) - (oldVotes * oldVotes);
    }

    /*
     * Compra tokens para un usuario.
     */
    function _buyTokensFor(
        address buyer,
        uint etherAmount
    ) internal returns (uint) {
        require(buyer != address(0), "Direccion invalida");
        require(etherAmount >= tokenPrice, "Ether insuficiente");
        require(etherAmount % tokenPrice == 0, "Ether incorrecto");

        uint numTokens = etherAmount / tokenPrice;

        votingToken.mint(buyer, numTokens);

        return numTokens;
    }

    /*
     * Comprueba que el contrato externo implementa IExecutableProposal.
     *
     * Version mas ligera que try/catch para reducir bytecode.
     * Si se pasa un contrato que no implementa ERC165, la llamada revertira.
     */
    function _supportsExecutableProposal(
        address executableContract
    ) internal view returns (bool) {
        if (executableContract.code.length == 0) {
            return false;
        }

        return IERC165(executableContract).supportsInterface(
            type(IExecutableProposal).interfaceId
        );
    }

    /*
     * Indica si se puede reclamar devolucion en una propuesta.
     */
    function _canClaimRefund(
        Proposal storage proposal
    ) internal view returns (bool) {
        if (proposal.status == ProposalStatus.Cancelled) {
            return true;
        }

        if (proposal.status == ProposalStatus.Approved) {
            return false;
        }

        return (
            proposal.status == ProposalStatus.Pending &&
            roundStatus[proposal.roundId] == RoundStatus.Closed
        );
    }

    /*
     * Ether disponible para recomprar tokens.
     */
    function _availableEtherForTokenSales() internal view returns (uint) {
        if (address(this).balance <= totalBudget) {
            return 0;
        }

        return address(this).balance - totalBudget;
    }
}