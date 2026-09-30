// SPDX-License-Identifier: Unlicenced
pragma solidity 0.8.34;
contract TokenContract {

 address public owner;
 struct Receivers {
 string name;
 uint256 tokens;
 }
 uint256 public constant price = 5 ether;
 mapping(address => Receivers) public users;

 modifier onlyOwner(){
 require(msg.sender == owner);
 _;
 }

 constructor(){
 owner = msg.sender;
 users[owner].tokens = 100;
 }

 function double(uint _value) public pure returns (uint){
 return _value*2;
 }

 function register(string memory _name) public{
  users[msg.sender].name = _name;
 }

 function giveToken(address _receiver, uint256 _amount) onlyOwner public{
 require(users[owner].tokens >= _amount);
 users[owner].tokens -= _amount;
 users[_receiver].tokens += _amount;
 }
 function buyToken(uint256 _amount) public payable {
    require(_amount > 0, "Debes comprar al menos 1 token");
    require(users[owner].tokens >= _amount, "No hay suficientes tokens");
    require(msg.value == _amount * price, "ETH insuficiente");

    users[owner].tokens -= _amount;
    users[msg.sender].tokens += _amount;
}

}
