using System;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace Server.Elements
{
    public class User : GameElement
    {
        public User(string name) : base(ElementType.USER, name)
        {
        }
    }
}
