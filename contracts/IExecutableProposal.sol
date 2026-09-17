// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/*
 * Interfaz que deben implementar todos los contratos externos de propuesta.
 *
 * El contrato QuadraticVoting no sabe que hace internamente cada propuesta.
 * Lo unico que exige es que tenga esta funcion para poder ejecutarla cuando
 * corresponda.
 *
 * Heredamos de IERC165 porque el enunciado exige que el sistema pueda comprobar
 * que el contrato externo implementa realmente esta interfaz.
 */
interface IExecutableProposal is IERC165 {
    function executeProposal(
        uint proposalId,
        uint numVotes,
        uint numTokens
    ) external payable;
}