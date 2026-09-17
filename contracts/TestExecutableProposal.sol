// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import "./IExecutableProposal.sol";

/*
 * Contrato de prueba para simular una propuesta externa.
 *
 * Este contrato sirve para comprobar en Remix que:
 * - la llamada externa se realiza correctamente;
 * - la propuesta recibe Ether si es de financiacion;
 * - se registran los votos y tokens con los que se ejecuto.
 *
 * Ademas hereda de ERC165 para que QuadraticVoting pueda comprobar que
 * realmente implementa la interfaz IExecutableProposal.
 */
contract TestExecutableProposal is ERC165, IExecutableProposal {
    event ProposalExecuted(
        uint proposalId,
        uint numVotes,
        uint numTokens,
        uint etherReceived,
        uint contractBalance
    );

    /*
     * Funcion que QuadraticVoting llamara cuando:
     * - una propuesta de financiacion sea aprobada;
     * - una propuesta de signaling se ejecute despues del cierre.
     */
    function executeProposal(
        uint proposalId,
        uint numVotes,
        uint numTokens
    ) external payable override {
        emit ProposalExecuted(
            proposalId,
            numVotes,
            numTokens,
            msg.value,
            address(this).balance
        );
    }

    /*
     * ERC165 permite que otro contrato pregunte:
     * "Implementas esta interfaz?"
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IExecutableProposal).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /*
     * Permitimos recibir Ether para las pruebas.
     */
    receive() external payable {}
}