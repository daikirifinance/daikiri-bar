// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.7.3;

library ExtendedMath {


    //return the smaller of the two inputs (a or b)
    function limitLessThan(uint a, uint b) internal pure returns (uint c) {

        if(a > b) return b;

        return a;

    }
}