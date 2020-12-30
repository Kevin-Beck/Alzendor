using System;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace AlzendorServer.Elements
{
    public class User
    {
        public string CharacterName { get; set; }
        private static int saltLength = 32;
        public byte[] Salt { get; set; }
        public string SaltedPassword { get; set; }
        public List<string> ChatChannels = new List<string>();

        public User(string name)
        {
            CharacterName = name;
            GenerateSalt();
        }
        public byte[] GetSalt()
        {
            if(Salt == null || Salt.Length == 0)
            {
                GenerateSalt();
            }
            return Salt;
        }
        public void GenerateSalt()
        {
            Salt = new byte[saltLength];
            using (var random = new RNGCryptoServiceProvider())
            {
                random.GetNonZeroBytes(Salt);
            }
        }
    }
}
