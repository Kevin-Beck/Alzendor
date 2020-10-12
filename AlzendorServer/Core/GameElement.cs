using System;
using System.Collections.Generic;

namespace Alzendor.Server
{
    public class GameElement
    {
        public bool IsDirty { get; set; }

        protected List<ConnectionToClient> subscribers = new List<ConnectionToClient>();
        public void AddSubscriber(ConnectionToClient subscriber)
        {
            if(subscriber == null)
            {
                Console.WriteLine("Subscriber was null, returning from game element AddSubscriber");
                return;
            }
            if(subscribers == null)
            {
                subscribers = new List<ConnectionToClient>();
            }
            subscribers.Add(subscriber);
        }
        public void RemoveSubscriber(ConnectionToClient subscriber)
        {
            subscribers.Remove(subscriber);
        }
    }
}
