using Server.Base;
using Server.Database;
using Server.Elements;
using System;
using System.Collections.Generic;
using System.Text;

namespace Server.Actions
{    public class LogInAction : ActionObject
    {
        public LogInStatus CurrentStep { get; set; }
        public string UserDataForStep { get; set; }
        public LogInAction(LogInStatus currentLogInStatus, string dataForStep) : base(dataForStep, ActionType.LOGIN, ElementType.PLAYER, dataForStep, ActionPriority.LOW)
        {
            CurrentStep = currentLogInStatus;
            UserDataForStep = dataForStep;
        }

        public override void ExecuteAction(IDatabaseWrapper storage, ConnectionToClient connection)
        {
            // The bool return value wasn't being used in ActionProcessor.cs nor was it being returned
            // So I've just commented this out for the time being

            /*
            if (CurrentStep == LogInStatus.RequestingSalt)
            {

                // get the user object from redis, get the salt from the user, send the salt back to the user
                return true;
            }
            else if (CurrentStep == LogInStatus.RequestingConfirmation)
            {
                // get the user object from redis, compare the logInData to the salted password stored
                // if they are equal the user has entered the correct password
                return true;
                // else return false
            }
            else if (CurrentStep == LogInStatus.LoggedIn)
            {
                // get the user object from redis, send all the channel subscribe commands to resub to the channels
                // put the player in the correct space/square and return the inventory objects to player
            }
            return false;
            */
        }
    }
}
