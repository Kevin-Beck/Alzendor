using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server.Core.Actions
{
    public class CreateAction : ActionObject
    {
        public string Sender { get; set; }
        public string TypeOfObjectToCreate { get; set; } // TODO maybe enum this to avoid magic strings
        public string NameOfCreatedObject { get; set; }
        public CreateAction(string sender,string typeOfObject, string nameOfObject) : base("Create", ActionPriority.LOW, ActionType.CREATE)
        {
            Sender = sender;
            NameOfCreatedObject = nameOfObject;
            TypeOfObjectToCreate = typeOfObject;
        }
    }
}

// TODO edit the base level of Action object to have sender and type, (channel, item, player etc)
// and standarize the name etc level of the actions, getting too wide
