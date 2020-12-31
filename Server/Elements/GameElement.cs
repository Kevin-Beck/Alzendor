using System.Collections.Generic;

namespace Server.Elements
{
    public class GameElement
    {
        public List<string> subscribers;
        public ElementType elementType;
        public string elementName;
        public GameElement(ElementType typeOfElement, string nameOfElement)
        {
            elementType = typeOfElement;
            elementName = nameOfElement;
            if(subscribers == null)
            {
                subscribers = new List<string>();
            }
        }
        public void AddSubscriber(string subscriber)
        {
            if(subscriber == null)
            {
                return;
            }
            if(subscribers == null)
            {
                subscribers = new List<string>();
            }
            subscribers.Add(subscriber);
        }
        public void RemoveSubscriber(string subscriber)
        {
            if(subscriber == null)
            {
                return;
            }
            if(subscribers == null)
            {
                return;
            }
            subscribers.Remove(subscriber);
        }
    }
}
