// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/*
 * Token ERC20 usado dentro del sistema de votacion.
 *
 * Cada participante compra estos tokens pagando Ether al contrato QuadraticVoting.
 * Despues, para votar, el participante debe hacer approve al contrato QuadraticVoting,
 * y QuadraticVoting usara transferFrom para bloquear los tokens necesarios.
 *
 * Decision de diseno:
 * - Usamos decimals() = 0 para que 1 token sea una unidad entera.
 * - Esto hace que el coste cuadratico sea mucho mas facil de entender:
 *      1 voto  = 1 token
 *      2 votos = 4 tokens
 *      3 votos = 9 tokens
 *
 * Seguridad:
 * - Solo el contrato QuadraticVoting puede crear tokens.
 * - Solo el contrato QuadraticVoting puede destruir tokens.
 * - Asi evitamos que cualquier usuario cree tokens falsos o destruya tokens ajenos.
 */
contract VotingToken is ERC20 {
    // Contrato QuadraticVoting autorizado para crear y destruir tokens.
    address public immutable votingContract;

    // Numero maximo de tokens que podran existir simultaneamente.
    uint public immutable maxSupply;

    /*
     * Modificador para restringir funciones criticas.
     *
     * Se usa en mint y burn para garantizar que solo QuadraticVoting pueda
     * modificar la oferta total del token.
     */
    modifier onlyVotingContract() {
        require(msg.sender == votingContract, "Solo puede ejecutarlo el contrato de votacion");
        _;
    }

    constructor(
        uint maxSupply_,
        address votingContract_
    ) ERC20("Quadratic Voting Token", "QVT") {
        require(maxSupply_ > 0, "El maximo de tokens debe ser mayor que cero");
        require(votingContract_ != address(0), "Direccion del contrato de votacion no valida");

        maxSupply = maxSupply_;
        votingContract = votingContract_;
    }

    /*
     * Sobrescribimos decimals para trabajar con tokens enteros.
     *
     * Por defecto, ERC20 suele usar 18 decimales. Para este proyecto no nos interesa,
     * porque queremos que los votos y los tokens sean faciles de calcular.
     */
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    /*
     * Crea tokens nuevos para un participante.
     *
     * Solo puede llamarla QuadraticVoting cuando un usuario compra tokens.
     */
    function mint(address to, uint amount) external onlyVotingContract {
        require(to != address(0), "Direccion de receptor no valida");
        require(amount > 0, "La cantidad debe ser mayor que cero");
        require(totalSupply() + amount <= maxSupply, "Se supera el maximo de tokens");

        _mint(to, amount);
    }

    /*
     * Destruye tokens.
     *
     * Se usa cuando:
     * - un participante vende tokens al sistema;
     * - una propuesta de financiacion se aprueba y los tokens usados se consumen.
     */
    function burn(address from, uint amount) external onlyVotingContract {
        require(from != address(0), "Direccion de cuenta no valida");
        require(amount > 0, "La cantidad debe ser mayor que cero");

        _burn(from, amount);
    }
}