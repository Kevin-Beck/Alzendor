using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server
{
    public class ServerObject
    {
        public bool IsDirty { get; set; }

        protected List<ConnectionToClient> subscribers;
        public void AddSubscriber(ConnectionToClient subscriber)
        {
            subscribers.Add(subscriber);
        }
        public void RemoveSubscriber(ConnectionToClient subscriber)
        {
            subscribers.Remove(subscriber);
        }
    }
}
